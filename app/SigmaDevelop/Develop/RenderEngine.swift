import CoreGraphics
import Foundation
import SigmaFoveon

/// A `CGImage` ferried across concurrency domains. `CGImage` is immutable and
/// thread-safe; the wrapper just satisfies `Sendable` checking.
struct RenderedImage: @unchecked Sendable {
    let cgImage: CGImage
    var autoExposureEV: Float = 0
    var isHDR: Bool = false
    var width: Int { cgImage.width }
    var height: Int { cgImage.height }
}

/// Bridges SwiftUI to FoveonDeveloper
final class RenderEngine: @unchecked Sendable {
    private let developer = FoveonDeveloper()
    // `.default`, not `.userInitiated`: the Rust decoder spawns its own worker pool
    // at default QoS and parks the calling thread on it. A higher-QoS queue here
    // would make a user-initiated thread wait on default-QoS workers — a priority
    // inversion the runtime flags as a hang risk. Matching QoS avoids the inversion.
    private let queue = DispatchQueue(label: "global.sigma.render", qos: .default)

    private var decodeKey: String?
    private var decoded: DecodedRaw?

    private var developKey: DevelopKey?
    private var developed: DevelopedImage?

    private struct DevelopKey: Equatable {
        let decode: String
        let exposure: Float
        let autoTone: Bool
        let autoExposureMode: AutoExposureMode?
        let toneKey: Float?
        let filmMeter: Bool?
        let denoise: DenoiseMode
        let denoiseStrength: Float?
        let denoiseChroma: Float?
        let denoiseTime: Float?
        let denoiseEnsemble: Bool?
        let denoiseModels: [String]?
    }

    /// Small grid thumbnail, developed with `settings` so the gallery matches the
    /// editor and the export. Decodes straight through rather than via the preview
    /// cache: every grid cell is a different file, so caching here would only evict
    /// the active viewer's decode.
    func thumbnail(url: URL, settings: DevelopSettings, maxDimension: Int) async throws -> RenderedImage {
        try await run {
            var options = settings.foveonOptions()
            // Wavelet is cheap enough for grid cells and keeps them matching the
            // editor; neural (seconds per image) stays editor/export-only.
            if options.denoise == .neural { options.denoise = .off }
            options.hdr = false // sdr only preview thumbnails
            // Half-res Rust proxy: a 700px thumbnail never needs the full 4.7MP develop.
            let decoded = try self.developer.decode(file: url, proxy: true)
            guard let cg = self.developer.previewImage(decoded, options: options,
                                                       maxDimension: maxDimension) else {
                throw FoveonError.render("thumbnail render returned nil")
            }
            return RenderedImage(cgImage: cg)
        }
    }


    func downscale(_ image: RenderedImage, maxDimension: Int) async -> RenderedImage {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: RenderedImage(cgImage: Self.resample(image.cgImage, to: maxDimension)))
            }
        }
    }

    /// Full-quality on-screen preview honouring `settings`, downscaled to
    /// `maxDimension` for speed. Reuses the cached decode + denoise when only the
    /// cheaper finishing knobs changed.
    func preview(url: URL, settings: DevelopSettings, maxDimension: Int?) async throws -> RenderedImage {
        try await run {
            let options = settings.foveonOptions()
            let developed = try self.developCached(url: url, options: options)
            guard let cg = self.developer.previewImage(developed, options: options,
                                                       maxDimension: maxDimension) else {
                throw FoveonError.render("preview render returned nil")
            }
            let isHDR = options.hdr && (cg.colorSpace.map(CGColorSpaceUsesExtendedRange) ?? false)
            return RenderedImage(cgImage: cg, autoExposureEV: developed.autoExposureEV, isHDR: isHDR)
        }
    }

    /// Encode `url` to the requested format and write it off the main actor.
    func export(url: URL, settings: DevelopSettings, format: ExportFormat, to outputURL: URL) async throws -> URL {
        try await run {
            let data = try self.exportData(url: url, settings: settings, format: format)
            try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: outputURL, options: .atomic)
            return outputURL
        }
    }

    /// One image to develop and write in a concurrent batch.
    struct ExportJob: Sendable {
        let url: URL
        let settings: DevelopSettings
        let format: ExportFormat
        let outputURL: URL
    }

    func exportBatch(_ jobs: [ExportJob], onProgress: @escaping @Sendable (Int, Int) -> Void) async throws -> [URL] {
        let foveonJobs = jobs.map {
            FoveonJob(input: $0.url,
                      targets: [FoveonTarget($0.format.outputFormat, $0.outputURL)],
                      options: $0.settings.foveonOptions())
        }
        let results = await developer.process(foveonJobs, onProgress: onProgress)
        return try results.indices.map { i in
            switch results[i] {
            case .success: return jobs[i].outputURL
            case .failure(let error): throw error
            }
        }
    }

    /// Drop the cached decode + denoise (e.g. when leaving a viewer) to free buffers.
    func releaseCache() {
        queue.async {
            self.decodeKey = nil; self.decoded = nil
            self.developKey = nil; self.developed = nil
            self.developer.releaseTransientResources()
        }
    }

    // MARK: -

    /// Must run on `queue`; the cache is single-threaded by construction
    private func decodeCached(url: URL) throws -> DecodedRaw {
        let key = decodeIdentity(url: url)
        if decodeKey == key, let decoded { return decoded }
        let fresh = try developer.decode(file: url)
        decodeKey = key
        decoded = fresh
        return fresh
    }

    private func developCached(url: URL, options: FoveonOptions) throws -> DevelopedImage {
        let raw = try decodeCached(url: url)
        let keyMeter = options.autoTone && options.autoExposureMode == .key
        let key = DevelopKey(
            decode: decodeIdentity(url: url),
            exposure: options.exposure, autoTone: options.autoTone,
            autoExposureMode: options.autoTone ? options.autoExposureMode : nil,
            toneKey: keyMeter ? options.toneKey : nil,
            filmMeter: keyMeter ? (options.film != nil) : nil,
            denoise: options.denoise,
            denoiseStrength: options.denoise != .off ? options.denoiseStrength : nil,
            denoiseChroma: options.denoise == .wavelet ? options.denoiseChroma : nil,
            denoiseTime: options.denoise == .neural ? options.denoiseTime : nil,
            denoiseEnsemble: options.denoise == .neural ? options.denoiseEnsemble : nil,
            denoiseModels: options.denoise == .neural ? options.denoiseModels.map(\.path) : nil)
        if developKey == key, let developed { return developed }
        let fresh = developer.develop(raw, options: options)
        developKey = key
        developed = fresh
        return fresh
    }

    private func decodeIdentity(url: URL) -> String {
        url.path
    }

    private func exportData(url: URL, settings: DevelopSettings, format: ExportFormat) throws -> Data {
        let options = settings.foveonOptions()
        switch format {
        case .dng:
            return try developer.render(x3f: try Data(contentsOf: url), to: .dng, options: options)
        case .tiff:
            return try developer.encode(decodeCached(url: url), as: .tiff, options: options)
        case .heic, .jpeg:
            let developed = try developCached(url: url, options: options)
            return try developer.encode(developer.finish(developed, options: options),
                                        as: format.outputFormat, quality: options.quality)
        }
    }

    private static func resample(_ image: CGImage, to maxDimension: Int) -> CGImage {
        let usesExtendedRange = image.colorSpace.map(CGColorSpaceUsesExtendedRange) ?? false
        let longest = max(image.width, image.height)
        guard longest > maxDimension || usesExtendedRange else { return image }

        let scale = min(CGFloat(maxDimension) / CGFloat(longest), 1)
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        let space = usesExtendedRange
            ? (CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB())
            : (image.colorSpace ?? CGColorSpaceCreateDeviceRGB())
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    private func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async { cont.resume(with: Result { try work() }) }
        }
    }
}
