#!/usr/bin/env python3
import struct, sys

# --- Camera Raw develop settings (edit here) -------------------------------
# Every key below is verified against this machine's Lightroom catalog
# (Adobe_imageDevelopSettings) — no speculative keys. Two requested adjustments
# are intentionally absent because they are NOT `crs:` attributes and cannot be
# expressed in XMP; apply them from Lightroom's Presets panel instead:
#   • AI Denoise (amount 67)  — the "Enhance" neural pipeline (see enhance.applescript)
#   • Adaptive Color (32)     — an Adobe Adaptive AI preset (isAdobeAdaptive)
CRS = {
    "Version": "18.3",            # Camera Raw version (matches installed LrC)
    "ProcessVersion": "15.4",     # current process version
    "HasSettings": "True",
    "WhiteBalance": "Auto",       # Lightroom auto white balance
    "Sharpness": "49",            # Detail panel sharpening amount
    "ShadowTint": "+28",          # Calibration panel shadow tint
    "HDREditMode": "1",           # HDR optimisation ("HDR enhanced")
    "HDRMaxValue": "2.3",         # HDR headroom (stops above SDR white)
    "AutoLateralCA": "1",         # remove lateral chromatic aberration (profile-free)
    "LensProfileEnable": "1",     # enable lens profile corrections (distortion/vignette)
    # Sigma 30mm F1.4 DC HSM | Art (A013), bound explicitly by name+filename (verified
    # installed .lcp). No native Sigma SA-mount build ships, but the optical correction
    # is mount-independent; Lr applies the named profile directly.
    "LensProfileSetup": "LensDefaults",
    "LensProfileName": "Adobe (SIGMA 30mm F1.4 DC HSM A013, NIKON CORPORATION)",
    "LensProfileFilename": "NIKON CORPORATION (SIGMA 30mm F1.4 DC HSM A013) - RAW.lcp",
    "LensProfileDistortionScale": "100",
    "LensProfileChromaticAberrationScale": "100",
    "LensProfileVignettingScale": "100",
}

XMP_TMPL = (
    '<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>\n'
    '<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="sd14-pipeline">\n'
    ' <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n'
    '  <rdf:Description rdf:about=""\n'
    '    xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"\n'
    '{attrs}>\n'
    '  </rdf:Description>\n'
    ' </rdf:RDF>\n'
    '</x:xmpmeta>\n'
    '<?xpacket end="w"?>'
)

def xmp_packet() -> bytes:
    attrs = "\n".join(f'    crs:{k}="{v}"' for k, v in CRS.items())
    return XMP_TMPL.format(attrs=attrs).encode("utf-8")

# --- minimal little-endian TIFF re-muxer ------------------------------------
TS = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 7: 1, 9: 4, 10: 8, 11: 4, 12: 8}

def inject(src: str, dst: str) -> None:
    d = open(src, "rb").read()
    if d[:2] != b"II" or struct.unpack("<H", d[2:4])[0] != 42:
        sys.exit("not a little-endian TIFF/DNG")
    u16 = lambda o: struct.unpack("<H", d[o:o + 2])[0]
    u32 = lambda o: struct.unpack("<I", d[o:o + 4])[0]
    le16 = lambda v: struct.pack("<H", v)
    le32 = lambda v: struct.pack("<I", v)

    def read_ifd(off):
        n = u16(off); ents = []
        for i in range(n):
            e = off + 2 + i * 12
            tag, typ, cnt = u16(e), u16(e + 2), u32(e + 4)
            tot = TS.get(typ, 1) * cnt
            data = d[e + 8:e + 8 + tot] if tot <= 4 else d[u32(e + 8):u32(e + 8) + tot]
            ents.append([tag, typ, cnt, bytes(data)])
        return ents

    ifd0 = read_ifd(u32(4))
    sub_off = next((struct.unpack("<I", x[3])[0] for x in ifd0 if x[0] == 330), None)
    subf = read_ifd(sub_off) if sub_off else []

    def strip(ents):
        o = c = 0
        for t, _, _, dat in ents:
            if t == 273: o = struct.unpack("<I", dat)[0]
            if t == 279: c = struct.unpack("<I", dat)[0]
        return o, c
    ro, rc = strip(ifd0); po, pc = strip(subf)
    raw, prev = d[ro:ro + rc], d[po:po + pc]

    # add/replace XMP (tag 700, BYTE)
    xmp = xmp_packet()
    ifd0 = [e for e in ifd0 if e[0] != 700]
    ifd0.append([700, 1, len(xmp), xmp])
    ifd0.sort(key=lambda e: e[0]); subf.sort(key=lambda e: e[0])

    n0, n1 = len(ifd0), len(subf)
    sub_new = 8 + 2 + 12 * n0 + 4
    heap_off = sub_new + 2 + 12 * n1 + 4

    def emit(ents, heap):
        body = bytearray(le16(len(ents)))
        for t, ty, c, dat in ents:
            body += le16(t) + le16(ty) + le32(c)
            if len(dat) <= 4:
                body += dat + bytes(4 - len(dat))
            else:
                body += le32(heap_off + len(heap)); heap += dat
                if len(heap) % 2: heap += b"\x00"
        return body + le32(0)

    for e in ifd0:
        if e[0] == 330: e[3] = le32(sub_new)
    heap = bytearray(); emit(ifd0, heap); emit(subf, heap)        # size heap
    ps = heap_off + len(heap); ps += ps & 1
    rs = ps + len(prev); rs += rs & 1
    for e in subf:
        if e[0] == 273: e[3] = le32(ps)
    for e in ifd0:
        if e[0] == 273: e[3] = le32(rs)
    heap = bytearray(); b0 = emit(ifd0, heap); b1 = emit(subf, heap)

    out = bytearray(b"II" + le16(42) + le32(8) + b0 + b1 + heap)
    out += b"\x00" * (ps - len(out)); out += prev
    out += b"\x00" * (rs - len(out)); out += raw
    open(dst, "wb").write(out)
    print(f"{src} -> {dst}  [+XMP {len(xmp)}B: {', '.join(CRS)}]")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    src = sys.argv[1]
    dst = sys.argv[2] if len(sys.argv) > 2 else src.rsplit(".", 1)[0] + ".lr.dng"
    inject(src, dst)
