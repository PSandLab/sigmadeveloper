import CFoveonRaw
import CoreImage
import Foundation
import simd

// Profile-driven lens correction (distortion + lateral CA + vignetting)

/// As-shot lens metadata from the X3F `PROP` section, for profile selection.
struct LensShot: Sendable {
    let focal: Float        // mm
    let aperture: Float     // f-number
    let focalMin: Float     // lens focal range (= focal for a prime)
    let focalMax: Float
    let apertureMax: Float  // widest aperture (smallest f-number)
    /// Body lens code (LENSMODEL; 0 = absent, 255 = unknown to the body).
    /// Range matching stays primary — codes only distinguish lenses the body's
    /// firmware knows — but a known code can veto a range false-positive.
    let model: UInt32

    init?(_ info: FoveonInfo) {
        guard info.focal_length > 0 else { return nil }
        focal = info.focal_length
        aperture = info.aperture
        focalMin = info.focal_min > 0 ? info.focal_min : info.focal_length
        focalMax = info.focal_max > 0 ? info.focal_max : info.focal_length
        apertureMax = info.aperture_max
        model = info.lens_model
    }
}

enum LensProfileTable {
    /// Match a shot to a profile by focal range + max aperture
    /// focal range is the primary key....
    static func match(_ shot: LensShot) -> LensProfile? {
        let isZoom = shot.focalMax > shot.focalMin + 0.5
        // my prime postdates the sd14 body
        if !isZoom, shot.model != 0, shot.model != 255 { return nil }
        let candidates = lensProfiles.filter {
            $0.isZoom == isZoom
                && approx($0.focalMin, shot.focalMin)
                && approx($0.focalMax, shot.focalMax)
        }
        guard candidates.count > 1 else { return candidates.first }
        // Tie-break by nearest max aperture (zoom max-f varies with focal).
        return candidates.min {
            abs($0.maxAperture - shot.apertureMax) < abs($1.maxAperture - shot.apertureMax)
        }
    }

    private static func approx(_ a: Float, _ b: Float, tol: Float = 0.06) -> Bool {
        a > 0 && b > 0 && abs(a - b) <= tol * max(a, b)
    }
}

/// SD14 Foveon sensor (20.7 × 13.8 mm): half-diagonal in mm. The Adobe model is
/// focal-length-normalised (r = sensorRadius / focal), so the image corner maps
/// to r = halfDiagonal / focal — independent of the body the profile was shot on.
private let sd14HalfDiagonalMM: Float = 12.44

/// Per-shot correction coefficients resolved from a matched profile, plus the
/// Metal-kernel application. `nil`-returning init means "no profile" → no-op.
struct LensCorrection: Sendable {
    let focal: Float
    let distortion: SIMD3<Float>
    let caRed: CA
    let caBlue: CA
    let vignette: SIMD3<Float>   // aperture-resolved α; .zero → no vignette

    init?(_ shot: LensShot?) {
        guard let shot, let profile = LensProfileTable.match(shot) else { return nil }
        focal = max(shot.focal, 1)
        let (lo, hi, t) = bracket(profile.samples, key: \.focal, value: focal)
        distortion = mix(lo.distortion, hi.distortion, t: t)
        caRed = mix(lo.caRed, hi.caRed, t: t)
        caBlue = mix(lo.caBlue, hi.caBlue, t: t)
        vignette = mix(Self.vignette(lo.vignette, fnumber: shot.aperture),
                       Self.vignette(hi.vignette, fnumber: shot.aperture), t: t)
    }

    /// Resolve a focal sample's per-aperture vignette to the shot's aperture:
    /// interpolate between sampled stops; past the deepest one, hold it (clamp).
    /// Adobe profiles vignette only wide-open + a stop or two; the residual at the
    /// deepest stop is mostly aperture-independent natural falloff, so clamping
    /// (as Lightroom does) keeps correcting it rather than fading it away.
    private static func vignette(_ samples: [VignetteSample], fnumber: Float) -> SIMD3<Float> {
        guard let first = samples.first, fnumber > 0 else { return .zero }
        let av = 2 * log2(fnumber)                       // APEX aperture value
        if av <= first.av { return first.a }             // at/within wide-open
        guard let i = samples.firstIndex(where: { $0.av >= av }) else {
            return samples[samples.count - 1].a          // clamp past deepest stop
        }
        return mix(samples[i - 1].a, samples[i].a, t: (av - samples[i - 1].av) / (samples[i].av - samples[i - 1].av))
    }

    /// Apply the correction to a scene-linear image, preserving its extent.
    func apply(to image: CIImage) -> CIImage {
        guard let kernel = lensKernel else { return image }
        let extent = image.extent
        guard !extent.isInfinite, extent.width >= 2, extent.height >= 2 else { return image }

        let cornerPx = 0.5 * Float(hypot(extent.width, extent.height))
        let rNorm = (sd14HalfDiagonalMM / focal) / cornerPx   // pixels → focal-normalised r
        let margin = roiMargin(cornerPx: cornerPx)

        let out = kernel.apply(
            extent: extent,
            roiCallback: { _, rect in rect.insetBy(dx: -margin, dy: -margin) },
            arguments: [
                image.clampedToExtent(),
                CIVector(x: extent.midX, y: extent.midY), Double(rNorm * rNorm),
                vec(distortion),
                Double(caRed.scale), vec(caRed.k),
                Double(caBlue.scale), vec(caBlue.k),
                vec(vignette),
            ])
        return out ?? image
    }
}

// MARK: - Helpers

extension LensCorrection {
    /// ROI margin = largest per-channel source displacement (px) over the frame.
    /// Composes the green distortion into red/blue exactly as the kernel does, and
    /// samples radially since the peak isn't always at the corner for steep zoom terms.
    fileprivate func roiMargin(cornerPx: Float) -> CGFloat {
        let rCorner = sd14HalfDiagonalMM / focal
        var shift: Float = 0
        for i in 1...16 {
            let f = Float(i) / 16
            let r2 = (rCorner * f) * (rCorner * f), r4 = r2 * r2, r6 = r4 * r2
            let g = 1 + distortion.x * r2 + distortion.y * r4 + distortion.z * r6
            let sr = g * caRed.scale * (1 + caRed.k.x * r2 + caRed.k.y * r4 + caRed.k.z * r6)
            let sb = g * caBlue.scale * (1 + caBlue.k.x * r2 + caBlue.k.y * r4 + caBlue.k.z * r6)
            shift = max(shift, max(abs(g - 1), abs(sr - 1), abs(sb - 1)) * cornerPx * f)
        }
        return CGFloat(shift) + 2
    }
}

private func vec(_ v: SIMD3<Float>) -> CIVector {
    CIVector(x: CGFloat(v.x), y: CGFloat(v.y), z: CGFloat(v.z))
}

private func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, t: Float) -> SIMD3<Float> {
    a + (b - a) * t
}

private func mix(_ a: CA, _ b: CA, t: Float) -> CA {
    CA(scale: a.scale + (b.scale - a.scale) * t, k: mix(a.k, b.k, t: t))
}

/// Bracket `value` in an ascending-by-`key` array, returning the two enclosing
/// elements and the 0…1 blend between them (clamped to the ends).
private func bracket<T>(_ a: [T], key: (T) -> Float, value: Float) -> (T, T, Float) {
    let lo = a.first!, hi = a.last!
    if value <= key(lo) { return (lo, lo, 0) }
    if value >= key(hi) { return (hi, hi, 0) }
    let i = a.firstIndex { key($0) >= value }!
    let span = key(a[i]) - key(a[i - 1])
    return (a[i - 1], a[i], span > 0 ? (value - key(a[i - 1])) / span : 0)
}

/// precompiled Core Image kernel (see build_metallib.sh)
private let lensKernel: CIKernel? = {
    guard let data = foveonMetalLibrary else { return nil }
    do {
        return try CIKernel(functionName: "lensCorrect", fromMetalLibraryData: data)
    } catch {
        warnStderr("lens-correction kernel load failed: \(error)")
        return nil
    }
}()
