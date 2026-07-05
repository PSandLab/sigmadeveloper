import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

let extendedLinearSRGB = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let displayP3ColorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
let extendedLinearDisplayP3ColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!

/// Rec.709 luma weights; share this between scene analysis & metering
let rec709Luma = SIMD3<Float>(0.2126, 0.7152, 0.0722)

/// Emit a `foveon: …` diagnostic line to standard error.
func warnStderr(_ message: String) {
    FileHandle.standardError.write(Data("foveon: \(message)\n".utf8))
}

/// Sharpen radius at full resolution. A downscaled preview scales it by its reduction
/// factor so the on-screen sharpening matches what the full-res export will produce.
let baseSharpnessRadius: Float = 1.6

/// Scene-linear value the SDR grade folds down to display white
let sdrSourceHeadroom: Float = 2.0

/// Perceptual-luma window over which the HDR gain ramps
let hdrGainRamp: (lo: Float, hi: Float) = (0.5, 1.0)

/// Floor of the SDR output clamp in the linear-sRGB working space
/// wide-gamut chroma survives to the P3/HEIC encode
let sdrClampFloor: CGFloat = -0.6

/// Auto-tone meters this much brighter when a film simulation is active. Film stocks are
/// calibrated to an ~18% mid-grey, whereas the digital finish keys darker and lets its
/// filmic S-curve lift the midtones afterwards — a lift the film path deliberately skips.
/// Without this, an auto-toned scene lands in the stock's toe and reads dark/heavy.
/// (+0.85 EV ≈ 0.07 → 0.13 target.)
let filmToneBoostEV: Float = 0.85

/// ETTR auto-exposure
let ettrPercentile: Float = 0.995
let ettrTarget: Float = 0.90

/// Gray-pixel auto-WB
let wbShadowFloor: Float = 0.004
let wbHighlightCeil: Float = 1.0
let wbSatSoftMax: Float = 0.55

/// log2 span of the scene max-channel histogram for ETTR percentiles
let sceneHistBins = 256
let sceneHistLogMin: Float = -16
let sceneHistLogMax: Float = 8

/// Metering + neutral estimate
struct SceneStats: Sendable {
    /// Geometric-mean (log-average) Rec.709 luminance
    let key: Float
    let wbNeutral: SIMD3<Float>?
    let maxChannelHist: [UInt32]
    let sampleCount: Int

    /// Scene-linear max-channel value @ cumulative fraction `p` (0…1)
    func maxChannelPercentile(_ p: Float) -> Float {
        guard sampleCount > 0 else { return 1 }
        let threshold = UInt32((p * Float(sampleCount)).rounded(.up))
        var cum: UInt32 = 0
        for (bin, c) in maxChannelHist.enumerated() {
            cum += c
            if cum >= threshold {
                let t = (Float(bin) + 0.5) / Float(sceneHistBins)
                return exp2(sceneHistLogMin + t * (sceneHistLogMax - sceneHistLogMin))
            }
        }
        return exp2(sceneHistLogMax)
    }
}

/// Precompiled gainExtend colour kernel (see build_metallib.sh)
private let gainExtendKernel: CIColorKernel? = {
    guard let data = foveonMetalLibrary else { return nil }
    do {
        return try CIKernel(functionName: "gainExtend", fromMetalLibraryData: data) as? CIColorKernel
    } catch {
        warnStderr("gainExtend kernel load failed: \(error)")
        return nil
    }
}()

/// Tone/Exposure/HDR management
extension FoveonDeveloper {

    /// Develop a scene-linear image, when requested, an HDR sibling for the ISO gain map.
    func render(_ linear: CIImage, _ o: FoveonOptions, isX3F: Bool, monoWeights: SIMD3<Float>? = nil,
                lens: LensCorrection? = nil) -> (sdr: CIImage, hdr: CIImage?) {
        // Honour requested quarter-turns
        let turns = ((o.rotate % 4) + 4) % 4
        let image = turns == 0 ? linear : linear.oriented(forExifOrientation: [1, 6, 3, 8][turns])
        // 1 proxy analysis feeds both auto-exposure and auto-WB.
        let stats = (o.autoTone || o.wb == .auto) ? analyzeScene(of: image) : nil
        let developed = developLinear(image, o, isX3F: isX3F, stats: stats)
        return tone(developed.image, o, monoWeights: monoWeights, wbNeutral: stats?.wbNeutral, lens: lens)
    }

    /// - Returns: the developed image, and the EV auto-exposure applied (0 when `autoTone` is off).
    ///   Denoising is calibrated for only Foveon
    func developLinear(_ linear: CIImage, _ o: FoveonOptions, isX3F: Bool, stats: SceneStats? = nil) -> (image: CIImage, autoEV: Float) {
        var autoEV: Float = 0
        if o.autoTone, let stats = stats ?? analyzeScene(of: linear) {
            autoEV = autoExposureEV(stats, o)
        }
        let ev = o.exposure + autoEV
        let exposed = ev != 0
            ? linear.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev])
            : linear

        // Denoise in scene-linear space
        let mode: DenoiseMode = isX3F ? o.denoise : .off
        let denoised: CIImage
        let strength = o.denoiseStrength ?? mode.defaultStrength
        switch mode {
        case .off:
            denoised = exposed
        case .wavelet:
            let noise = sd14BaseNoise.pushed(by: exp2(ev))
            denoised = WaveletDenoise.shared?.apply(
                exposed, noise: noise, strength: strength,
                chroma: o.denoiseChroma) ?? exposed
        case .neural:
            denoised = denoiser(for: o)?.denoise(
                exposed, context: context, strength: strength,
                ensemble: o.denoiseEnsemble, time: o.denoiseTime) ?? exposed
        }
        return (denoised, autoEV)
    }

    func tone(_ clean: CIImage, _ o: FoveonOptions, monoWeights: SIMD3<Float>? = nil,
              wbNeutral: SIMD3<Float>? = nil, scale: Float = 1,
              lens: LensCorrection? = nil) -> (sdr: CIImage, hdr: CIImage?) {
        let balanced = whiteBalanced(clean, o, neutral: wbNeutral)
        let corrected = (o.lensCorrection ? lens : nil)?.apply(to: balanced) ?? balanced
        let filmed = film(corrected, o, scale: scale)
        let base = o.monochrome ? monochrome(filmed, weights: monoWeights) : filmed

        // The print paper already tone-maps, so a developed film look skips the digital tonemap.
        let sdr = finish(base, o, sharpnessRadius: baseSharpnessRadius * scale,
                         tonemapped: o.film == nil)
        let hdr = o.hdr ? hdrExtend(sdr: sdr, o, extent: base.extent) : nil
        return (sdr, hdr)
    }

    /// Spectral film simulation on scene-linear
    private func film(_ image: CIImage, _ o: FoveonOptions, scale: Float) -> CIImage {
        guard let settings = o.film, let sim = FilmSimulation.shared else { return image }
        return sim.apply(image, settings, scale: 1 / max(scale, 1e-4)).cropped(to: image.extent)
    }

    /// one gpu op
    private func monochrome(_ image: CIImage, weights: SIMD3<Float>?) -> CIImage {
        let w = weights ?? rec709Luma
        let luma = CIVector(x: CGFloat(w.x), y: CGFloat(w.y), z: CGFloat(w.z), w: 0)
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": luma,
            "inputGVector": luma,
            "inputBVector": luma,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }

    /// Post-decode white balance over as-shot baseline
    private func whiteBalanced(_ image: CIImage, _ o: FoveonOptions, neutral: SIMD3<Float>?) -> CIImage {
        switch o.wb {
        case .asShot:
            return image
        case .auto:
            guard let n = neutral else { return image }   // no estimate → trust as-shot
            // Green-normalised gain that neutralises the estimated illuminant.
            func clamp(_ v: Float) -> Float { min(max(v, 0.5), 2.0) }
            let g = SIMD3<Float>(clamp(n.y / max(n.x, 1e-4)), 1, clamp(n.y / max(n.z, 1e-4)))
            return channelGain(image, g)
        case let .temperature(kelvin, tint):
            let f = CIFilter.temperatureAndTint()
            f.inputImage = image
            f.neutral = CIVector(x: CGFloat(kelvin), y: CGFloat(tint))
            f.targetNeutral = CIVector(x: 6500, y: 0)
            return (f.outputImage ?? image).cropped(to: image.extent)
        }
    }

    /// Per-channel diagonal gain
    private func channelGain(_ image: CIImage, _ g: SIMD3<Float>) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(g.x), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: CGFloat(g.y), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(g.z), w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }

    /// Shared perceptual finishing
    private func finish(_ base: CIImage, _ o: FoveonOptions, sharpnessRadius: Float,
                        tonemapped: Bool) -> CIImage {
        var img = tonemapped ? tonemap(base, sourceHeadroom: sdrSourceHeadroom) : base
        img = img.applyingFilter("CILinearToSRGBToneCurve")
        if tonemapped { img = filmicTone(img) }
        if let c = o.contrast {
            img = img.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.0 + CGFloat(c)])
        }
        if o.sharpness > 0 {
            img = img.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: o.sharpness, kCIInputRadiusKey: CGFloat(sharpnessRadius),
            ])
        }
        img = img.applyingFilter("CISRGBToneCurveToLinear")
        return clampSDR(img).cropped(to: base.extent)
    }

    /// Bound the SDR output to display white while retaining gamut
    private func clampSDR(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: sdrClampFloor, y: sdrClampFloor, z: sdrClampFloor, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
        ])
    }

    /// HDR
    private func hdrExtend(sdr: CIImage, _ o: FoveonOptions, extent: CGRect) -> CIImage? {
        let stops = o.hdrEV
        guard stops > 0, let kernel = gainExtendKernel else { return nil }
        let hdr = kernel.apply(extent: extent, arguments: [sdr, stops, hdrGainRamp.lo, hdrGainRamp.hi])
        return hdr?.cropped(to: extent).settingContentHeadroom(exp2(stops))
    }

    private func tonemap(_ image: CIImage, sourceHeadroom: Float, targetHeadroom: Float = 1.0) -> CIImage {
        let f = CIFilter.toneMapHeadroom()
        f.inputImage = image
        f.sourceHeadroom = sourceHeadroom
        f.targetHeadroom = targetHeadroom
        return f.outputImage ?? image
    }

    /// Gentle toe
    private func filmicTone(_ image: CIImage) -> CIImage {
        let c = CIFilter.toneCurve()
        c.inputImage = image
        c.point0 = CGPoint(x: 0.00, y: 0.00)
        c.point1 = CGPoint(x: 0.13, y: 0.016)
        c.point2 = CGPoint(x: 0.33, y: 0.25)
        c.point3 = CGPoint(x: 0.66, y: 0.73)
        c.point4 = CGPoint(x: 1.00, y: 0.99)
        return c.outputImage ?? image
    }

    /// Analyse a scene-linear image @ 256px in one proxy render
    func analyzeScene(of image: CIImage) -> SceneStats? {
        let extent = image.extent
        guard !extent.isInfinite, extent.width > 0, extent.height > 0 else { return nil }
        let scale = min(1, 256 / max(extent.width, extent.height))
        let w = max(1, Int((extent.width * scale).rounded()))
        let h = max(1, Int((extent.height * scale).rounded()))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let count = w * h
        // context.render fills the entire (0,0,w,h) region, so the readback
        // buffer needs no zero-fill before it; skip the full-frame memset
        let buf = [Float](unsafeUninitializedCapacity: count * 4) { raw, initialized in
            context.render(small, toBitmap: raw.baseAddress!, rowBytes: w * 16,
                           bounds: CGRect(x: 0, y: 0, width: w, height: h),
                           format: .RGBAf, colorSpace: extendedLinearSRGB)
            initialized = count * 4
        }

        var hist = [UInt32](repeating: 0, count: sceneHistBins)
        var logSum: Float = 0                                 // Σ ln(luminance) → geometric mean
        var wSum: Float = 0, wR: Float = 0, wG: Float = 0, wB: Float = 0
        let binScale = Float(sceneHistBins) / (sceneHistLogMax - sceneHistLogMin)

        buf.withUnsafeBufferPointer { p in
            let s = p.baseAddress!
            for i in 0..<count {
                let r = s[i * 4], g = s[i * 4 + 1], b = s[i * 4 + 2]
                let y = rec709Luma.x * r + rec709Luma.y * g + rec709Luma.z * b
                logSum += log(max(y, 1e-4))

                let mx = max(r, max(g, b)), mn = min(r, min(g, b))
                if mx > 0 {
                    let bin = Int((log2(mx) - sceneHistLogMin) * binScale)
                    hist[min(max(bin, 0), sceneHistBins - 1)] += 1
                }
                // Gray-pixel vote: near-neutral mid-tones only.
                if y > wbShadowFloor, mx < wbHighlightCeil, mx > 0 {
                    var wt = 1 - (mx - mn) / mx / wbSatSoftMax   // (mx-mn)/mx = saturation
                    if wt > 0 {
                        wt *= wt                                 // sharpen the neutral preference
                        wSum += wt; wR += wt * r; wG += wt * g; wB += wt * b
                    }
                }
            }
        }

        let key = max(exp(logSum / Float(count)), 1e-4)
        let neutral: SIMD3<Float>? = (wSum >= 0.01 * Float(count) && wR > 0 && wG > 0 && wB > 0)
            ? SIMD3<Float>(wR / wSum, wG / wSum, wB / wSum) : nil
        return SceneStats(key: key, wbNeutral: neutral, maxChannelHist: hist, sampleCount: count)
    }

    private func autoExposureEV(_ stats: SceneStats, _ o: FoveonOptions) -> Float {
        let ev: Float
        switch o.autoExposureMode {
        case .ettr:
            // Expose the highlight percentile up (or down) to ETTR target
            let hi = stats.maxChannelPercentile(ettrPercentile)
            ev = log2f(ettrTarget / max(hi, 1e-4))
        case .key:
            // Film exposes to ~18% mid-grey, so meter brighter than digital
            let target = o.film != nil ? o.toneKey * exp2(filmToneBoostEV) : o.toneKey
            ev = log2f(target / stats.key)
        }
        return min(max(ev, -3.0), 4.0)
    }
}
