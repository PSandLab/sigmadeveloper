// verifytiles

import CoreGraphics
import Foundation
import SigmaFoveon

let inputs = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
guard !inputs.isEmpty else {
    FileHandle.standardError.write(Data("usage: verifytiles <files...>\n".utf8))
    exit(2)
}

let regions = [
    CGRect(x: 0.25, y: 0.30, width: 0.40, height: 0.35), // interior
    CGRect(x: 0.00, y: 0.00, width: 0.50, height: 0.50), // top-left corner
    CGRect(x: 0.60, y: 0.55, width: 0.40, height: 0.45), // bottom-right corner
]

struct Case { let name: String; let mutate: (inout FoveonOptions) -> Void }
let cases = [
    Case(name: "sdr") { $0.hdr = false },
    Case(name: "sdr-noLens") { $0.hdr = false; $0.lensCorrection = false },
    Case(name: "sdr+rot1") { $0.hdr = false; $0.rotate = 1 },
    Case(name: "hdr+autoTone") { $0.hdr = true; $0.autoTone = true },
]

func bytes(_ image: CGImage) -> (data: Data, bytesPerRow: Int, bytesPerPixel: Int) {
    let data = image.dataProvider!.data! as Data
    return (data, image.bytesPerRow, image.bitsPerPixel / 8)
}

/// Max per-channel difference between the tile and the same pixel window of
/// the full render. SDR compares 8-bit levels; HDR compares decoded float16s.
func maxDelta(full: CGImage, fullBytes: (data: Data, bytesPerRow: Int, bytesPerPixel: Int),
              tile: CGImage, at region: CGRect, hdr: Bool) -> Double {
    let (fullData, fullBPR, bpp) = fullBytes
    let (tileData, tileBPR, _) = bytes(tile)
    let x0 = Int((region.minX * CGFloat(full.width)).rounded())
    let y0 = Int((region.minY * CGFloat(full.height)).rounded())
    var worst = 0.0
    for row in 0..<tile.height {
        let fullRow = fullData.dropFirst((y0 + row) * fullBPR + x0 * bpp).prefix(tile.width * bpp)
        let tileRow = tileData.dropFirst(row * tileBPR).prefix(tile.width * bpp)
        if !hdr {
            for (a, b) in zip(fullRow, tileRow) where a != b {
                worst = max(worst, Double(a > b ? a - b : b - a))
            }
        } else {
            let f = [UInt8](fullRow), t = [UInt8](tileRow)
            for i in stride(from: 0, to: f.count, by: 2) {
                let av = Float16(bitPattern: UInt16(f[i]) | UInt16(f[i + 1]) << 8)
                let bv = Float16(bitPattern: UInt16(t[i]) | UInt16(t[i + 1]) << 8)
                // A NaN delta must FAIL the verifier, not silently vanish through max().
                let d = abs(Double(av) - Double(bv))
                worst = max(worst, d.isNaN ? .infinity : d)
            }
        }
    }
    return worst
}

let developer = FoveonDeveloper()
var failures = 0

for url in inputs {
    let decoded: DecodedRaw
    do {
        decoded = try developer.decode(file: url, proxy: false)
    } catch {
        print("\(url.lastPathComponent): decode failed — \(error)")
        failures += 1
        continue
    }

    // The gating contract the app relies on: an X3F under the preview cap
    // rasterises on its native grid (no tiles needed); larger files preview
    // below nativeLongEdge (tiles engage).
    var gateOptions = FoveonOptions()
    gateOptions.hdr = false
    let developed = developer.develop(decoded, options: gateOptions)
    if let capped = developer.previewImage(developed, options: gateOptions, maxDimension: 2560) {
        let previewLong = max(capped.width, capped.height)
        let atNative = previewLong >= developed.nativeLongEdge - 8
        print("\(url.lastPathComponent): native \(developed.nativeLongEdge)px, capped preview " +
              "\(previewLong)px → tiles \(atNative ? "off (native)" : "on")")
    } else {
        print("\(url.lastPathComponent): capped preview render failed")
        failures += 1
    }

    for c in cases {
        var options = FoveonOptions()
        c.mutate(&options)
        let dev = developer.develop(decoded, options: options)
        guard let full = developer.previewImage(dev, options: options, maxDimension: nil) else {
            print("  \(c.name): full render failed"); failures += 1; continue
        }
        // Extract the full-frame bytes once per case, not once per region.
        let fullBytes = bytes(full)
        for region in regions {
            guard let (tile, actual) = developer.previewImage(dev, options: options,
                                                              region: region, maxDimension: nil) else {
                print("  \(c.name) \(region): region render failed"); failures += 1; continue
            }
            let delta = maxDelta(full: full, fullBytes: fullBytes, tile: tile, at: actual, hdr: options.hdr)
            // Measured baselines: RAW/DNG and lens-correction-off X3F are
            // bit-exact (Δ0). Lens correction resamples, so its crop-boundary
            // pixels drift ≤2 8-bit levels / ≤0.03 linear — sub-visible. A real
            // ROI regression (content shift) shows up as tens of levels.
            let pass = options.hdr ? delta <= 0.05 : delta <= 2
            if !pass { failures += 1 }
            print(String(format: "  %@ region(%.2f,%.2f,%.2f,%.2f) %dx%d maxΔ %.4f %@",
                         c.name, region.minX, region.minY, region.width, region.height,
                         tile.width, tile.height, delta, pass ? "PASS" : "FAIL"))
        }
    }
}

exit(failures == 0 ? 0 : 1)
