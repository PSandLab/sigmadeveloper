import CoreImage
import Foundation
import Metal
import os

// MARK: - Public configuration

/// `dng`/`tiff` are decode targets;
/// `jpeg`/`heic` additionally run the Core Image render
public enum OutputFormat: String, Sendable, CaseIterable {
    case dng, tiff, jpeg, heic

    public var fileExtension: String {
        switch self {
        case .dng: "dng"
        case .tiff: "tif"
        case .jpeg: "jpg"
        case .heic: "heic"
        }
    }
}

/// Auto-exposure metering w/ ETTR (highlight-percentile) & Key (log-average mid-grey).
public enum AutoExposureMode: String, Sendable, CaseIterable, Codable, Hashable {
    case ettr, key
}

/// Post-Decode White balance
public enum WhiteBalanceMode: Sendable, Equatable {
    case asShot
    case auto
    case temperature(kelvin: Float, tint: Float)
}

/// edge-avoiding à-trous denoising + neural coreML
public enum DenoiseMode: String, Sendable, CaseIterable, Codable, Hashable {
    case off, wavelet, neural
    public var defaultStrength: Float {
        self == .wavelet ? 0.67 : 1
    }
}

/// knobs
public struct FoveonOptions: Sendable {
    public var quality: Double = 0.92
    public var sharpness: Float = 0.5
    public var contrast: Float? = nil        // nil → none
    public var exposure: Float = 0           // EV, on top of auto-tone
    public var autoTone = true               // auto-expose (see `autoExposureMode`)
    public var autoExposureMode: AutoExposureMode = .ettr
    public var toneKey: Float = 0.07         // `key` mode target
    public var monochrome = false            // black & white
    public var hdr = true                    // embed an ISO HDR gain map
    public var hdrEV: Float = 2.3            // highlight headroom in stops @ white
    public var wb: WhiteBalanceMode = .asShot // post-decode white balance
    public var lensCorrection = true         // profile-driven distortion/CA/vignette (x3f)
    public var film: FilmSimSettings? = nil  // spectral film simulation (nil → off)
    public var denoise: DenoiseMode = .off   // wavelet (profiled) or neural (Core ML)
    /// wavelet: threshold scale; neural: 0…1 blend. nil → the mode's `defaultStrength`.
    public var denoiseStrength: Float? = nil
    public var denoiseChroma: Float = 2      // wavelet: extra chroma shrink multiplier
    public var denoiseModels: [URL] = []     // neural: empty → auto-discover; >1 → cascade
    public var denoiseTime: Float = 0.85     // neural JiT t: 1≈clean/input, 0≈pure noise
    public var denoiseEnsemble = false       // neural 8-way D4 self-ensemble (8× cost)

    public init() {}
}

public struct FoveonTarget: Sendable {
    public var format: OutputFormat
    public var url: URL
    public init(_ format: OutputFormat, _ url: URL) {
        self.format = format
        self.url = url
    }
}

public struct FoveonJob: Sendable {
    public var input: URL
    public var targets: [FoveonTarget]
    public var options: FoveonOptions

    public init(input: URL, targets: [FoveonTarget], options: FoveonOptions = .init()) {
        self.input = input
        self.targets = targets
        self.options = options
    }
}

// MARK: - Developer

/// Embeddable Foveon X3F developer for iOS/macOS
public final class FoveonDeveloper: @unchecked Sendable {
    let context: CIContext
    private let denoiserState = OSAllocatedUnfairLock(initialState: DenoiserCache())

    private struct DenoiserCache {
        var denoisers: [String: FoveonDenoiser] = [:]
        var badKeys: Set<String> = []
        var warnedNoModel = false
    }

    public init() {
        self.context = FoveonDeveloper.makeContext()
    }

    /// Lazily load (and cache) the neural denoiser for these options, or nil when
    /// denoising is off or no model is available. Shared across concurrent jobs.
    func denoiser(for o: FoveonOptions) -> FoveonDenoiser? {
        guard o.denoise == .neural else { return nil }
        let urls = o.denoiseModels.isEmpty ? FoveonDenoiser.discover() : o.denoiseModels
        guard !urls.isEmpty else {
            denoiserState.withLock { state in
                if !state.warnedNoModel {
                    state.warnedNoModel = true
                    FileHandle.standardError.write(Data("foveon: --denoise set but no Core ML model found (pass --denoise-model, or place FoveonJiT.mlpackage beside the binary / in the app bundle)\n".utf8))
                }
            }
            return nil
        }
        let key = urls.map(\.path).joined(separator: "|")
        return denoiserState.withLock { state in
            if let cached = state.denoisers[key] { return cached }
            guard !state.badKeys.contains(key) else { return nil }
            do {
                let made = try FoveonDenoiser(modelURLs: urls)
                state.denoisers[key] = made
                return made
            } catch {
                state.badKeys.insert(key)
                FileHandle.standardError.write(Data("foveon: failed to load denoise model(s): \(key): \(error)\n".utf8))
                return nil
            }
        }
    }

    /// Free transient GPU working sets (the wavelet denoiser's pooled pyramid
    /// textures). Call when an interactive viewer goes away; steady-state
    /// rendering re-warms the pool on first use.
    public func releaseTransientResources() {
        WaveletDenoise.shared?.drain()
    }

    public func render(x3f: Data, to format: OutputFormat, options: FoveonOptions = .init()) throws -> Data {
        // The Rust decode always renders the authentic as-shot baseline (nil WB);
        // white balance is a post-decode finishing adjustment (see `options.wb`).
        switch format {
        case .dng:
            return try renderX3F(x3f, mode: .dng, whiteBalance: nil).data
        case .tiff:
            return try renderX3F(x3f, mode: .tiffLinearF16, whiteBalance: nil).data
        case .jpeg, .heic:
            let raw = try renderX3F(x3f, mode: .tiffLinearF16, whiteBalance: nil)
            return try encode(renderImage(raw, options), as: format, quality: options.quality)
        }
    }

    /// Render an already-decoded image file (RAW, DNG, TIFF, JPEG, …)
    public func render(file url: URL, to format: OutputFormat, options: FoveonOptions = .init()) throws -> Data {
        switch format {
        case .jpeg, .heic:
            return try encode(render(loadLinear(url), options, isX3F: false), as: format, quality: options.quality)
        case .dng, .tiff:
            throw FoveonError.badInput("\(format.rawValue) output requires an .x3f input")
        }
    }

    /// overlap for compute saturation
    @discardableResult
    public func process(_ jobs: [FoveonJob], maxConcurrent: Int? = nil,
                        onProgress: (@Sendable (Int, Int) -> Void)? = nil) async -> [Result<Void, Error>] {
        let defaultLimit = jobs.contains { $0.options.denoise == .neural }
            ? 1 : ProcessInfo.processInfo.activeProcessorCount
        let limit = max(1, maxConcurrent ?? defaultLimit)
        var results = [Result<Void, Error>?](repeating: nil, count: jobs.count)

        await withTaskGroup(of: (Int, Result<Void, Error>).self) { group in
            var next = 0
            func submit() {
                guard next < jobs.count else { return }
                let i = next
                let job = jobs[i]
                next += 1
                group.addTask {
                    do {
                        try await self.runBlocking { try self.processOne(job) }
                        return (i, .success(()))
                    } catch {
                        return (i, .failure(error))
                    }
                }
            }
            for _ in 0..<min(limit, jobs.count) { submit() }
            var completed = 0
            while let (i, r) = await group.next() {
                results[i] = r
                completed += 1
                onProgress?(completed, jobs.count)
                submit()
            }
        }
        return results.map { $0 ?? .failure(FoveonError.render("job not run")) }
    }

    // MARK: - Internals

    private func processOne(_ job: FoveonJob) throws {
        if job.input.pathExtension.lowercased() == "x3f" {
            try processX3F(job)
        } else {
            try processImage(job)
        }
    }

    private func processX3F(_ job: FoveonJob) throws {
        let x3f = try Data(contentsOf: job.input)
        // only one decode
        var decoder: RawDecoder?
        func prepared() throws -> RawDecoder {
            if let decoder { return decoder }
            let d = try RawDecoder(x3f: x3f)
            decoder = d
            return d
        }
        var tiff: RawRender?
        var rendered: (sdr: CIImage, hdr: CIImage?)?
        func tiffData() throws -> RawRender {
            if let t = tiff { return t }
            let t = try prepared().render(mode: .tiffLinearF16)
            tiff = t
            return t
        }
        func renderedImage() throws -> (sdr: CIImage, hdr: CIImage?) {
            if let f = rendered { return f }
            let f = try renderImage(tiffData(), job.options)
            rendered = f
            return f
        }

        for target in job.targets {
            let data: Data
            switch target.format {
            case .dng:  data = try prepared().render(mode: .dng).data
            case .tiff: data = try tiffData().data
            case .jpeg, .heic: data = try encode(renderedImage(), as: target.format, quality: job.options.quality)
            }
            try data.write(to: target.url, options: .atomic)
        }
    }

    /// Render a non-X3F input (RAW/DNG/TIFF/JPEG/…) to the requested image format(s)
    private func processImage(_ job: FoveonJob) throws {
        var rendered: (sdr: CIImage, hdr: CIImage?)?
        func renderedImage() throws -> (sdr: CIImage, hdr: CIImage?) {
            if let r = rendered { return r }
            let r = render(try loadLinear(job.input), job.options, isX3F: false)
            rendered = r
            return r
        }
        for target in job.targets {
            switch target.format {
            case .jpeg, .heic:
                let data = try encode(renderedImage(), as: target.format, quality: job.options.quality)
                try data.write(to: target.url, options: .atomic)
            case .dng, .tiff:
                throw FoveonError.badInput("\(target.format.rawValue) output requires an .x3f input")
            }
        }
    }

    /// Numeric rank of a `CIRAWDecoderVersion` ("version8" → 8); unversioned
    /// entries (e.g. `.none`) rank lowest so they are never auto-selected.
    private func decoderRank(_ v: CIRAWDecoderVersion) -> Int {
        Int(v.rawValue.filter(\.isNumber)) ?? -1
    }

    /// Camera RAW containers Core Image can demosaic via `CIRAWFilter`.
    private static let rawExtensions: Set<String> = [
        "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "sr2", "srf",
        "raf", "rw2", "orf", "pef", "raw", "rwl", "dcr", "kdc", "mrw", "3fr", "fff",
    ]

    /// Load any decoded image into a scene-linear `CIImage` for the finishing graph.
    /// RAW/DNG demosaic through `CIRAWFilter`; other files honour their embedded
    /// profile, falling back to scene-linear for our untagged f16 TIFF intermediate.
    func loadLinear(_ url: URL) throws -> CIImage {
        if FoveonDeveloper.rawExtensions.contains(url.pathExtension.lowercased()) {
            guard let filter = CIRAWFilter(imageURL: url) else {
                throw FoveonError.badInput("could not decode RAW: \(url.lastPathComponent)")
            }
            // Use Raw9
            if let newest = filter.supportedDecoderVersions
                .max(by: { decoderRank($0) < decoderRank($1) }) {
                filter.decoderVersion = newest
            }
            // Embedded DNG opcode / maker profiles (distortion, CA, vignette)
            if filter.isLensCorrectionSupported { filter.isLensCorrectionEnabled = true }
            // Decode with full highlight headroom
            filter.extendedDynamicRangeAmount = 2
            guard let image = filter.outputImage else {
                throw FoveonError.badInput("could not decode RAW: \(url.lastPathComponent)")
            }
            return image
        }
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw FoveonError.badInput("could not load image: \(url.lastPathComponent)")
        }
        guard image.colorSpace != nil else {
            return CIImage(contentsOf: url, options: [
                .applyOrientationProperty: true, .colorSpace: extendedLinearSRGB,
            ]) ?? image
        }
        return image
    }

    /// Wrap developed-TIFF bytes in a `CIImage` and build the render graph.
    private func renderImage(_ raw: RawRender, _ o: FoveonOptions) throws -> (sdr: CIImage, hdr: CIImage?) {
        guard let image = CIImage(data: raw.data, options: [
            .colorSpace: extendedLinearSRGB,
            .applyOrientationProperty: true,
        ]) else {
            throw FoveonError.render("could not load developed TIFF")
        }
        return render(image, o, isX3F: true, monoWeights: raw.monoWeights, lens: LensCorrection(raw.lens))
    }

    /// Encode the rendered SDR image (with an optional HDR gain-map sibling).
    public func encode(_ rendered: (sdr: CIImage, hdr: CIImage?), as format: OutputFormat, quality: Double = 0.92) throws -> Data {
        let qualityKey = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        var options: [CIImageRepresentationOption: Any] = [qualityKey: quality]
        if let hdr = rendered.hdr { options[.hdrImage] = hdr }

        switch format {
        case .jpeg:
            let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
            guard let data = context.jpegRepresentation(of: rendered.sdr, colorSpace: sRGB, options: options) else {
                throw FoveonError.render("JPEG encode returned nil")
            }
            return data
        case .heic:
            let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
            return try context.heif10Representation(of: rendered.sdr, colorSpace: p3, options: options)
        case .dng, .tiff:
            throw FoveonError.render("\(format.rawValue) is not a rendered image format")
        }
    }

    /// Run blocking decode/render work on a GCD thread so the Swift cooperative
    /// pool is never starved while many images are processed at once.
    private func runBlocking(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .default).async {
                cont.resume(with: Result { try work() })
            }
        }
    }

    private static func makeContext() -> CIContext {
        let options: [CIContextOption: Any] = [
            .cacheIntermediates: false,
            .workingColorSpace: extendedLinearSRGB,
            .workingFormat: CIFormat.RGBAh,
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }
}
