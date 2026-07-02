#!/usr/bin/env python3
"""Distil Adobe LCP lens profiles into an embedded Swift table.

The SigmaDevelop app corrects distortion / lateral CA / vignetting from the same
Adobe LCP data Lightroom uses (see scripts/lr_prep.py). Rather than ship the 27 MB
of XML and parse it on-device, this generates a compact Swift source with just the
lenses we shoot, sampled at infinity focus over the lens's focal × aperture grid.
Distortion is aperture-independent; lateral CA is tiny (near-constant); vignetting
is strongly aperture-dependent — so we store distortion/CA per focal length and
vignetting per (focal, aperture).

Adobe model (verified): radius is focal-length-normalised, `r = sensorRadius/focal`.
  distortion : sourceRadius = r·(1 + k1·r² + k2·r⁴ + k3·r⁶)   [dest→source]
  lateral CA : per channel, ·ScaleFactor·(1 + kc1·r² + …) relative to green
  vignetting : illumination = 1 + a1·r² + a2·r⁴ + a3·r⁶ ; gain = 1/illumination

Usage:  python3 scripts/lcp_codegen.py   (writes the generated Swift file)
Re-run when the lens set changes; commit the output.
"""
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

RDF = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
LCP_ROOT = Path("/Library/Application Support/Adobe/CameraRaw/LensProfiles/1.0/Sigma")

# (Swift name, isZoom, lcp path). Bodies are mount-independent optically; we use
# the Nikon-bodied profiles to match the existing lr_prep.py Lightroom path.
LENSES = [
    ("SIGMA 30mm F1.4 DC HSM A013", False,
     LCP_ROOT / "Nikon/NIKON CORPORATION (SIGMA 30mm F1.4 DC HSM A013) - RAW.lcp"),
    ("SIGMA 70-300mm F4-5.6 DG MACRO", True,
     LCP_ROOT / "Nikon/NIKON CORPORATION (Sigma_70-300mm_F4-5.6_DG_MACRO ) - RAW.lcp"),
]

OUT = Path(__file__).resolve().parent.parent / \
    "develop/Sources/SigmaFoveon/LensProfiles.generated.swift"


def stns(xml):
    return re.search(r'xmlns:stCamera="([^"]+)"', xml).group(1)


def parse_lcp(path):
    xml = path.read_text(encoding="utf-8", errors="replace")
    st = stns(xml)
    A = lambda el, k: el.get(f"{{{st}}}{k}")
    fl = lambda el, t: el.find(f".//{{{st}}}{t}")

    models = []
    for desc in ET.fromstring(xml).iter(f"{{{RDF}}}Description"):
        if A(desc, "FocalLength") is None or A(desc, "ApertureValue") is None:
            continue
        pm, vm = fl(desc, "PerspectiveModel"), fl(desc, "VignetteModel")
        if pm is None and vm is None:
            continue
        m = {
            "focal": float(A(desc, "FocalLength")),
            "av": float(A(desc, "ApertureValue")),
            "focus": float(A(desc, "FocusDistance") or 0.0),
        }
        pmd = pm.find(f"{{{RDF}}}Description") if pm is not None else None
        if pmd is not None:
            m["dist"] = [float(A(pmd, f"RadialDistortParam{i}") or 0) for i in (1, 2, 3)]
            for tag, key in (("ChromaticRedGreenModel", "caR"),
                             ("ChromaticBlueGreenModel", "caB")):
                c = pmd.find(f"{{{st}}}{tag}")
                if c is not None:
                    m[key] = (float(A(c, "ScaleFactor") or 1),
                              [float(A(c, f"RadialDistortParam{i}") or 0) for i in (1, 2, 3)])
        if vm is not None:
            vmd = vm.find(f"{{{RDF}}}Description")
            if vmd is not None:
                m["vig"] = [float(A(vmd, f"VignetteModelParam{i}") or 0) for i in (1, 2, 3)]
        models.append(m)

    # Widest aperture the profile was measured at (smallest APEX Av), across all
    # focus/focal models — used for signature matching. Vignette alone is too
    # sparse (often only wide-open) to derive this from.
    min_av = min(m["av"] for m in models)

    # Distortion/CA: take the infinity-focus models (focus dependence is small and
    # the X3F only records focus *mode*, not distance, so we can't interpolate it).
    far = max(m["focus"] for m in models)
    far_models = [m for m in models if m["focus"] == far]

    samples = []
    for f in sorted({m["focal"] for m in far_models}):
        at_f = [m for m in far_models if m["focal"] == f]
        dist = next((m["dist"] for m in at_f if "dist" in m), [0, 0, 0])
        # CA is ~aperture-invariant: take the widest-aperture model that has it.
        wide = sorted(at_f, key=lambda m: m["av"])
        caR = next((m["caR"] for m in wide if "caR" in m), (1.0, [0, 0, 0]))
        caB = next((m["caB"] for m in wide if "caB" in m), (1.0, [0, 0, 0]))
        # Vignette: aperture-dependent and sparsely sampled (Adobe profiles it
        # densely wide-open, adds a stop or two only at closer focus). Build the
        # aperture series from the *farthest focus that profiles each aperture* —
        # the best infinity approximation per stop (e.g. A013: f/1.4 @ ∞, f/2 @ 2m).
        farthest_by_av = {}
        for m in (x for x in models if x["focal"] == f and "vig" in x):
            if m["av"] not in farthest_by_av or m["focus"] > farthest_by_av[m["av"]]["focus"]:
                farthest_by_av[m["av"]] = m
        vig = sorted((m["av"], m["vig"]) for m in farthest_by_av.values())
        samples.append({"focal": f, "dist": dist, "caR": caR, "caB": caB, "vig": vig})
    return samples, min_av


def v3(x):
    return f"SIMD3<Float>({x[0]:.6g}, {x[1]:.6g}, {x[2]:.6g})"


def emit(name, is_zoom, samples, min_av):
    fmin = min(s["focal"] for s in samples)
    fmax = max(s["focal"] for s in samples)
    # widest aperture → f-number from APEX Av: N = 2^(Av/2)
    max_ap = 2 ** (min_av / 2)
    lines = [f'    LensProfile(']
    lines.append(f'        name: "{name}", isZoom: {str(is_zoom).lower()},')
    lines.append(f'        focalMin: {fmin:g}, focalMax: {fmax:g}, maxAperture: {max_ap:.4g},')
    lines.append(f'        samples: [')
    for s in samples:
        vig = ", ".join(f"VignetteSample(av: {av:.6g}, a: {v3(a)})" for av, a in s["vig"])
        lines.append(f'            FocalSample(')
        lines.append(f'                focal: {s["focal"]:g}, distortion: {v3(s["dist"])},')
        lines.append(f'                caRed: CA(scale: {s["caR"][0]:.6g}, k: {v3(s["caR"][1])}),')
        lines.append(f'                caBlue: CA(scale: {s["caB"][0]:.6g}, k: {v3(s["caB"][1])}),')
        lines.append(f'                vignette: [{vig}]),')
    lines.append(f'        ]),')
    return "\n".join(lines)


def main():
    blocks = []
    for name, is_zoom, path in LENSES:
        if not path.exists():
            sys.exit(f"missing LCP: {path}")
        samples, min_av = parse_lcp(path)
        print(f"{name}: {len(samples)} focal sample(s), "
              f"{sum(len(s['vig']) for s in samples)} vignette point(s), "
              f"max f/{2 ** (min_av / 2):.2g}")
        blocks.append(emit(name, is_zoom, samples, min_av))

    header = '''// Generated by scripts/lcp_codegen.py — do not edit by hand.
// Adobe LCP lens-correction coefficients for the lenses we shoot, sampled at
// infinity focus. See LensCorrection.swift for the model and scripts/lcp_codegen.py
// for the source profiles. Radius is focal-length-normalised (r = sensorRadius/focal).
import simd

/// Lateral-CA radial model for one channel, relative to green.
struct CA: Sendable { let scale: Float; let k: SIMD3<Float> }
/// Vignette polynomial at one aperture: illumination = 1 + a·r² + a·r⁴ + a·r⁶.
struct VignetteSample: Sendable { let av: Float; let a: SIMD3<Float> }
/// One focal length's correction (a prime has a single sample; a zoom several).
struct FocalSample: Sendable {
    let focal: Float
    let distortion: SIMD3<Float>
    let caRed: CA
    let caBlue: CA
    let vignette: [VignetteSample]
}
/// An Adobe lens profile matched by focal range + max aperture (LENSMODEL is
/// unreliable on the SD14). `samples` are ordered by focal length.
struct LensProfile: Sendable {
    let name: String
    let isZoom: Bool
    let focalMin: Float
    let focalMax: Float
    let maxAperture: Float
    let samples: [FocalSample]
}

let lensProfiles: [LensProfile] = [
'''
    OUT.write_text(header + "\n".join(blocks) + "\n]\n", encoding="utf-8")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
