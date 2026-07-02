// imgmetrics.swift — objective image-difference metrics for the SD14 pipeline.
//
// Compares a candidate render (ours) against a reference (SIGMA Photo Pro) and
// reports perceptual CIEDE2000 colour difference plus mean CIELAB deltas, which
// decompose the gap into exposure (ΔL*) and colour-cast (Δa*, Δb*) terms. Both
// images are colour-managed into linear sRGB and resampled to a common size, so
// the score reflects tone/colour rather than pixel-exact detail or noise
//
//   swift imgmetrics.swift <candidate> <reference> [--size N] [--json]
//
// Exit code is 0 on success; the human summary goes to stdout, JSON (with --json)
// to stdout as the final line for easy batch aggregation.

import AppKit
import CoreImage
import Foundation

// MARK: - CLI

struct Args {
    var candidate: String
    var reference: String
    var size = 512          // long side of the common comparison raster
    var json = false
}

func parseArgs() -> Args {
    var positional: [String] = []
    var size = 512
    var json = false
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--size": if let v = it.next(), let n = Int(v) { size = max(32, n) }
        case "--json": json = true
        case "-h", "--help":
            fputs("usage: imgmetrics.swift <candidate> <reference> [--size N] [--json]\n", stderr)
            exit(2)
        default: positional.append(a)
        }
    }
    guard positional.count == 2 else {
        fputs("usage: imgmetrics.swift <candidate> <reference> [--size N] [--json]\n", stderr)
        exit(2)
    }
    return Args(candidate: positional[0], reference: positional[1], size: size, json: json)
}

// MARK: - Colour science

struct Lab { var L: Float; var a: Float; var b: Float }

/// Linear sRGB (D65) → CIELAB (D65 reference white).
@inline(__always)
func linearSRGBToLab(_ r: Float, _ g: Float, _ b: Float) -> Lab {
    // linear sRGB → XYZ (D65)
    let x = 0.4124564 * r + 0.3575761 * g + 0.1804375 * b
    let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
    let z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * b
    // normalise by D65 white
    let xn = x / 0.95047, yn = y / 1.00000, zn = z / 1.08883
    let f: (Float) -> Float = { t in
        t > 0.008856 ? powf(t, 1.0 / 3.0) : (7.787 * t + 16.0 / 116.0)
    }
    let fx = f(xn), fy = f(yn), fz = f(zn)
    return Lab(L: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
}

/// CIEDE2000 colour difference between two CIELAB samples.
func deltaE2000(_ s1: Lab, _ s2: Lab) -> Float {
    let kL: Float = 1, kC: Float = 1, kH: Float = 1
    let C1 = sqrtf(s1.a * s1.a + s1.b * s1.b)
    let C2 = sqrtf(s2.a * s2.a + s2.b * s2.b)
    let Cbar = (C1 + C2) / 2
    let Cbar7 = powf(Cbar, 7)
    let G = 0.5 * (1 - sqrtf(Cbar7 / (Cbar7 + powf(25, 7))))
    let a1p = (1 + G) * s1.a
    let a2p = (1 + G) * s2.a
    let C1p = sqrtf(a1p * a1p + s1.b * s1.b)
    let C2p = sqrtf(a2p * a2p + s2.b * s2.b)
    let h1p = atan2deg(s1.b, a1p)
    let h2p = atan2deg(s2.b, a2p)

    let dLp = s2.L - s1.L
    let dCp = C2p - C1p
    var dhp: Float = 0
    if C1p * C2p != 0 {
        let diff = h2p - h1p
        if abs(diff) <= 180 { dhp = diff }
        else if diff > 180 { dhp = diff - 360 }
        else { dhp = diff + 360 }
    }
    let dHp = 2 * sqrtf(C1p * C2p) * sinDeg(dhp / 2)

    let Lbarp = (s1.L + s2.L) / 2
    let Cbarp = (C1p + C2p) / 2
    var hbarp = h1p + h2p
    if C1p * C2p != 0 {
        if abs(h1p - h2p) > 180 { hbarp = (h1p + h2p + 360) / 2 }
        else { hbarp = (h1p + h2p) / 2 }
    } else {
        hbarp = h1p + h2p
    }
    let T = 1 - 0.17 * cosDeg(hbarp - 30) + 0.24 * cosDeg(2 * hbarp)
            + 0.32 * cosDeg(3 * hbarp + 6) - 0.20 * cosDeg(4 * hbarp - 63)
    let dTheta = 30 * expf(-powf((hbarp - 275) / 25, 2))
    let Cbarp7 = powf(Cbarp, 7)
    let RC = 2 * sqrtf(Cbarp7 / (Cbarp7 + powf(25, 7)))
    let SL = 1 + (0.015 * powf(Lbarp - 50, 2)) / sqrtf(20 + powf(Lbarp - 50, 2))
    let SC = 1 + 0.045 * Cbarp
    let SH = 1 + 0.015 * Cbarp * T
    let RT = -sinDeg(2 * dTheta) * RC

    let termL = dLp / (kL * SL)
    let termC = dCp / (kC * SC)
    let termH = dHp / (kH * SH)
    return sqrtf(termL * termL + termC * termC + termH * termH + RT * termC * termH)
}

@inline(__always) func atan2deg(_ y: Float, _ x: Float) -> Float {
    if y == 0 && x == 0 { return 0 }
    var d = atan2f(y, x) * 180 / .pi
    if d < 0 { d += 360 }
    return d
}
@inline(__always) func sinDeg(_ d: Float) -> Float { sinf(d * .pi / 180) }
@inline(__always) func cosDeg(_ d: Float) -> Float { cosf(d * .pi / 180) }

// MARK: - Rendering to a common linear-sRGB raster

let ciContext = CIContext(options: [
    .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
    .cacheIntermediates: false,
])

/// Load and resample an image to `w × h` interleaved RGBA float in *linear* sRGB.
func loadLinear(_ path: String, _ w: Int, _ h: Int) -> [Float]? {
    guard let img = CIImage(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    let e = img.extent
    guard e.width > 0, e.height > 0 else { return nil }
    let scaled = img
        .transformed(by: CGAffineTransform(scaleX: CGFloat(w) / e.width, y: CGFloat(h) / e.height))
        .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    var buf = [Float](repeating: 0, count: w * h * 4)
    let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    buf.withUnsafeMutableBytes { raw in
        ciContext.render(scaled, toBitmap: raw.baseAddress!, rowBytes: w * 16,
                         bounds: CGRect(x: 0, y: 0, width: w, height: h),
                         format: .RGBAf, colorSpace: linear)
    }
    return buf
}

// MARK: - Main

let args = parseArgs()

// Derive a common comparison raster from the reference's aspect ratio.
guard let refImg = CIImage(contentsOf: URL(fileURLWithPath: args.reference)) else {
    fputs("cannot open reference: \(args.reference)\n", stderr); exit(1)
}
let aspect = refImg.extent.width / max(refImg.extent.height, 1)
let (w, h) = aspect >= 1
    ? (args.size, max(1, Int((Float(args.size) / Float(aspect)).rounded())))
    : (max(1, Int((Float(args.size) * Float(aspect)).rounded())), args.size)

guard let candBuf = loadLinear(args.candidate, w, h),
      let refBuf = loadLinear(args.reference, w, h) else {
    fputs("failed to render one or both images\n", stderr); exit(1)
}

var sumDE: Double = 0, sumDE2: Double = 0, maxDE: Float = 0
var meanLab = (cL: 0.0, ca: 0.0, cb: 0.0, rL: 0.0, ra: 0.0, rb: 0.0)
let n = w * h
for i in 0..<n {
    let o = i * 4
    let cLab = linearSRGBToLab(candBuf[o], candBuf[o + 1], candBuf[o + 2])
    let rLab = linearSRGBToLab(refBuf[o], refBuf[o + 1], refBuf[o + 2])
    let de = deltaE2000(cLab, rLab)
    sumDE += Double(de); sumDE2 += Double(de) * Double(de)
    if de > maxDE { maxDE = de }
    meanLab.cL += Double(cLab.L); meanLab.ca += Double(cLab.a); meanLab.cb += Double(cLab.b)
    meanLab.rL += Double(rLab.L); meanLab.ra += Double(rLab.a); meanLab.rb += Double(rLab.b)
}
let nd = Double(n)
let meanDE = sumDE / nd
let rmsDE = (sumDE2 / nd).squareRoot()
let dL = (meanLab.cL - meanLab.rL) / nd
let da = (meanLab.ca - meanLab.ra) / nd
let db = (meanLab.cb - meanLab.rb) / nd

let candName = (args.candidate as NSString).lastPathComponent
let refName = (args.reference as NSString).lastPathComponent
print(String(format: "%@ vs %@", candName, refName))
print(String(format: "  meanΔE2000 = %.2f   rmsΔE = %.2f   maxΔE = %.2f", meanDE, rmsDE, maxDE))
print(String(format: "  ΔL* = %+.2f (exposure)   Δa* = %+.2f (green↔red)   Δb* = %+.2f (blue↔yellow)", dL, da, db))
print(String(format: "  cand L*a*b* = %.1f %+.1f %+.1f   ref L*a*b* = %.1f %+.1f %+.1f",
             meanLab.cL/nd, meanLab.ca/nd, meanLab.cb/nd, meanLab.rL/nd, meanLab.ra/nd, meanLab.rb/nd))
if args.json {
    print(String(format: "{\"cand\":\"%@\",\"ref\":\"%@\",\"meanDE\":%.4f,\"rmsDE\":%.4f,\"maxDE\":%.4f,\"dL\":%.4f,\"da\":%.4f,\"db\":%.4f}",
                 candName, refName, meanDE, rmsDE, maxDE, dL, da, db))
}
