import CoreGraphics
import Foundation
import SigmaFoveon
import os

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
    // handle QoS properly or else XCode gets made at me
    private let queue = DispatchQueue(label: "global.sigma.render", qos: .default)
    /// bound CPU thumbnails as CIRAW proxy decode is GPU bound
    private let thumbnailQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "global.sigma.render.thumbnails"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .default
        return queue
    }()
    /// Newest preview request
    private let previewGeneration = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    private struct DecodeKey: Equatable, Sendable {
        let path: String
        /// preview proxy decodes
        let proxy: Bool
    }
    /// Tiny MRU cache for decode
    private let decodeCache = OSAllocatedUnfairLock<[(key: DecodeKey, raw: DecodedRaw)]>(initialState: [])
    private static let decodeCacheCap = 3

    private var developKey: DevelopKey?
    private var developed: DevelopedImage?

    private struct DevelopKey: Equatable {
        let decode: DecodeKey
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
    /// editor and the export.
    func thumbnail(url: URL, settings: DevelopSettings, maxDimension: Int) async throws -> RenderedImage {
        try await runThumbnail {
            var options = settings.foveonOptions()
            // only allow wavelet
            if options.denoise == .neural { options.denoise = .off }
            options.hdr = false // sdr only preview thumbnails
            // Proxy decodes
            let decoded = try self.decodeCached(url: url, proxy: true)
            guard let cg = self.developer.previewImage(decoded, options: options,
                                                       maxDimension: maxDimension) else {
                throw FoveonError.render("thumbnail render returned nil")
            }
            return RenderedImage(cgImage: cg)
        }
    }


    func downscale(_ image: RenderedImage, maxDimension: Int) async -> RenderedImage {
        await withCheckedContinuation { continuation in
            thumbnailQueue.addOperation {
                continuation.resume(returning: RenderedImage(cgImage: Self.resample(image.cgImage, to: maxDimension)))
            }
        }
    }

    /// Full-quality on-screen preview honouring settings, downscaled to
    /// `maxDimension` for speed, delivered progressively
    /// Superseded requests are dropped before rendering, so it converges on current
    func previewUpdates(url: URL, settings: DevelopSettings, maxDimension: Int?) -> AsyncThrowingStream<RenderedImage, Error> {
        let generation = previewGeneration.withLock { g in g += 1; return g }
        return AsyncThrowingStream { continuation in
            self.queue.async {
                guard self.isCurrentPreview(generation) else { return continuation.finish() }
                do {
                    let options = settings.foveonOptions()
                    // Camera RAW edits from the rasterised proxy
                    let proxyPreviewed = Self.isProxyPreviewed(url)
                    if !proxyPreviewed, !self.hasCachedDecode(url: url, proxy: false),
                       let quick = try? self.renderPreview(url: url, options: options,
                                                           proxy: true, maxDimension: maxDimension) {
                        continuation.yield(quick)
                        guard self.isCurrentPreview(generation) else { return continuation.finish() }
                    }
                    continuation.yield(try self.renderPreview(url: url, options: options,
                                                              proxy: proxyPreviewed,
                                                              maxDimension: maxDimension))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func renderPreview(url: URL, options: FoveonOptions, proxy: Bool, maxDimension: Int?) throws -> RenderedImage {
        let developed = try developCached(url: url, options: options, proxy: proxy)
        guard let cg = developer.previewImage(developed, options: options,
                                              maxDimension: maxDimension) else {
            throw FoveonError.render("preview render returned nil")
        }
        let isHDR = options.hdr && (cg.colorSpace.map(CGColorSpaceUsesExtendedRange) ?? false)
        return RenderedImage(cgImage: cg, autoExposureEV: developed.autoExposureEV, isHDR: isHDR)
    }

    private func isCurrentPreview(_ generation: UInt64) -> Bool {
        previewGeneration.withLock { $0 == generation }
    }

    private func hasCachedDecode(url: URL, proxy: Bool) -> Bool {
        let key = DecodeKey(path: url.path, proxy: proxy)
        return decodeCache.withLock { cache in cache.contains { $0.key == key } }
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

    /// consider mem pressure
    func releaseAll() {
        decodeCache.withLock { $0.removeAll() }
        releaseTransient()
    }

    /// when leaving we weant to drop graph/gpu but keep MRU
    func releaseTransient() {
        queue.async {
            self.developKey = nil; self.developed = nil
            self.developer.releaseTransientResources()
        }
    }

    // MARK: -

    private func decodeCached(url: URL, proxy: Bool) throws -> DecodedRaw {
        let key = DecodeKey(path: url.path, proxy: proxy)
        // Any earlier decode of the same file provides scene analysis
        let (hit, donor) = decodeCache.withLock { cache -> (DecodedRaw?, DecodedRaw?) in
            if let i = cache.firstIndex(where: { $0.key == key }) {
                let entry = cache.remove(at: i)
                cache.append(entry)
                return (entry.raw, nil)
            }
            return (nil, cache.last(where: { $0.key.path == url.path })?.raw)
        }
        if let hit { return hit }
        // Decode outside the lock.
        let fresh = try developer.decode(file: url, proxy: proxy, reusing: donor)
        decodeCache.withLock { cache in
            cache.removeAll { $0.key == key }
            cache.append((key, fresh))
            if cache.count > Self.decodeCacheCap { cache.removeFirst() }
        }
        return fresh
    }

    private func developCached(url: URL, options: FoveonOptions, proxy: Bool) throws -> DevelopedImage {
        let raw = try decodeCached(url: url, proxy: proxy)
        let keyMeter = options.autoTone && options.autoExposureMode == .key
        let key = DevelopKey(
            decode: DecodeKey(path: url.path, proxy: proxy),
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

    /// The editor previews non-X3F camera RAW from a proxy decode
    private static func isProxyPreviewed(_ url: URL) -> Bool {
        url.pathExtension.lowercased() != "x3f"
    }

    private func exportData(url: URL, settings: DevelopSettings, format: ExportFormat) throws -> Data {
        let options = settings.foveonOptions()
        switch format {
        case .dng, .tiff:
            // Container formats come straight from the Rust core.
            return try developer.render(x3f: try Data(contentsOf: url), to: format.outputFormat, options: options)
        case .heic, .jpeg:
            guard Self.isProxyPreviewed(url) else {
                // X3F previews develop full-res, so the export reuses that work
                let developed = try developCached(url: url, options: options, proxy: false)
                return try developer.encode(developer.finish(developed, options: options),
                                            as: format.outputFormat, quality: options.quality)
            }
            // Camera RAW re-develops from the lazy full res graph
            return try developer.encode(decodeCached(url: url, proxy: false),
                                        as: format.outputFormat, options: options)
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

    private func runThumbnail<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            thumbnailQueue.addOperation { cont.resume(with: Result { try work() }) }
        }
    }
}
