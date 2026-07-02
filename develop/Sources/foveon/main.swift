import Foundation
import SigmaFoveon

// foveon — develop Sigma Foveon X3F into DNG/TIFF and/or JPEG/HEIC.

let usage = """
usage: foveon <input> [options]
  <input>          an .x3f / raw / dng / tiff / image file, or a folder
  -o, --out DIR    output dir
  --dng  --tiff    decoded intermediate(s)            (.x3f input only)
  --jpeg --heic    rendered image(s)  (default: --jpeg)
  -q, --quality Q  output quality 0…1 (default: 0.92)
  --wb MODE        white balance: as-shot | auto | <kelvin> (default: as-shot)
  --no-lens-correction  skip profile lens correction (default: on, .x3f only)
  --exposure EV    exposure compensation (default: 0)
  --no-auto-tone   disable auto exposure
  --auto-exposure M  metering: ettr | key (default: ettr)
  --tone-key K     `key` auto-exposure target (default: 0.07)
  --monochrom      black & white
  --contrast C     contrast #
  --sharpness S    sharpening # (default: 0.5)
  --sdr            skip HDR gain map
  --hdr-stops S    HDR highlight headroom (stops, default: 2.3)
  --film NAME      spectral film simulation with stock NAME (name/index; --film list)
  --paper NAME     RA4 print paper (default: Portra Endura)
  --film-negative  output the scanned negative/slide instead of an RA4 print
  --ev-film EV     film exposure (default: 0)
  --ev-paper EV    print exposure (default: auto neutral balance)
  --couplers AMT   DIR coupler amount, colourfulness (default: 0.25, 0 disables)
  --coupler-radius R  DIR coupler spatial diffusion, fraction of long edge (default: 0.0015)
  --halation       reddish halation glow bleeding out of the highlights
  --halation-strength S  halation glow scale (default: 0.35)
  --halation-radius R  halation radius, fraction of long edge (default: 0.0015)
  --halation-midtones M  halation highlight protection 0…1 (default: 0)
  --no-grain       disable film grain
  --grain-size S   grain size scale (default: 1)
  --denoise [MODE] denoise: wavelet (profiled à-trous, no model, default) | neural (Core ML)
  --denoise-strength S  strength: wavelet threshold scale / neural blend 0…1
                   (default: the mode's default — wavelet 0.67, neural 1)
  --denoise-chroma C  wavelet chroma shrink multiplier (default: 2)
  --denoise-model P  neural model .mlmodelc/.mlpackage; repeat to cascade (default: auto)
  --denoise-time T  neural JiT signal level t, 0…1 (default: 0.85; ignored by one-input models)
  --denoise-ensemble  neural 8-way self-ensemble (higher quality, 8× slower)
  -j, --jobs N     concurrent images (default: cores)
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("foveon: \(message)\n".utf8))
    exit(2)
}

/// Resolve a film/paper stock
func resolveStock(_ name: String, in stocks: [FilmStock], kind: String) -> Int {
    if let idx = Int(name), stocks.indices.contains(idx) { return stocks[idx].index }
    let q = name.lowercased()
    if let exact = stocks.first(where: { $0.key == q || $0.name.lowercased() == q }) { return exact.index }
    let hits = stocks.filter { $0.key.contains(q) || $0.name.lowercased().contains(q) }
    if hits.count == 1 { return hits[0].index }
    if hits.isEmpty { fail("unknown \(kind) '\(name)' (try --film list)") }
    fail("ambiguous \(kind) '\(name)': \(hits.map(\.key).joined(separator: ", "))")
}

func printStocks() {
    func list(_ label: String, _ stocks: [FilmStock]) {
        print(label)
        for s in stocks { print("  \(String(s.index).leftPadded(2))  \(s.key.rightPadded(34))\(s.name)") }
    }
    list("films (--film NAME):", FilmSimData.films)
    list("papers (--paper NAME):", FilmSimData.papers)
}

extension String {
    func leftPadded(_ n: Int) -> String { String(repeating: " ", count: max(0, n - count)) + self }
    func rightPadded(_ n: Int) -> String { self + String(repeating: " ", count: max(0, n - count)) }
}

let inputExtensions: Set<String> = [
    "x3f", "dng", "tif", "tiff", "jpg", "jpeg", "png", "heic", "heif",
    "cr2", "cr3", "crw", "nef", "nrw", "arw", "sr2", "srf",
    "raf", "rw2", "orf", "pef", "raw", "rwl", "dcr", "kdc", "mrw", "3fr", "fff",
]

func collectInputs(_ paths: [String]) -> [URL] {
    let fm = FileManager.default
    var files: [URL] = []
    for path in paths {
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { fail("no such file: \(path)") }
        if isDir.boolValue {
            let items = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            files += items.filter { inputExtensions.contains($0.pathExtension.lowercased()) }
        } else {
            files.append(url)
        }
    }
    return files.sorted { $0.path < $1.path }
}

let args = Array(CommandLine.arguments.dropFirst())
var formats: [OutputFormat] = []
var outDir: URL?
var options = FoveonOptions()
var film = FilmSimSettings()
var filmEnabled = false
var jobsLimit: Int?
var inputs: [String] = []

var i = 0
while i < args.count {
    let a = args[i]
    i += 1
    func take() -> String {
        guard i < args.count else { fail("missing value for \(a)") }
        defer { i += 1 }
        return args[i]
    }
    switch a {
    case "--dng": formats.append(.dng)
    case "--tiff": formats.append(.tiff)
    case "--jpeg", "--jpg": formats.append(.jpeg)
    case "--heic": formats.append(.heic)
    case "-o", "--out": outDir = URL(fileURLWithPath: take(), isDirectory: true)
    case "-q", "--quality": options.quality = Double(take()) ?? options.quality
    case "--wb":
        let v = take().lowercased()
        switch v {
        case "as-shot", "asshot", "shot": options.wb = .asShot
        case "auto": options.wb = .auto
        default:
            guard let k = Float(v.hasSuffix("k") ? String(v.dropLast()) : v) else {
                fail("--wb expects as-shot | auto | <kelvin>")
            }
            options.wb = .temperature(kelvin: k, tint: 0)
        }
    case "--no-lens-correction": options.lensCorrection = false
    case "--exposure": options.exposure = Float(take()) ?? options.exposure
    case "--no-auto-tone": options.autoTone = false
    case "--auto-exposure":
        guard let m = AutoExposureMode(rawValue: take().lowercased()) else {
            fail("--auto-exposure expects ettr | key")
        }
        options.autoExposureMode = m
    case "--tone-key": options.toneKey = Float(take()) ?? options.toneKey
    case "--monochrom": options.monochrome = true
    case "--contrast": options.contrast = Float(take())
    case "--sharpness": options.sharpness = Float(take()) ?? options.sharpness
    case "--sdr": options.hdr = false
    case "--hdr-stops": options.hdrEV = Float(take()) ?? options.hdrEV
    case "--film":
        let v = take()
        if v.lowercased() == "list" { printStocks(); exit(0) }
        filmEnabled = true
        // The stock implies paper / scan process / halation; later flags override.
        film = film.selecting(film: resolveStock(v, in: FilmSimData.films, kind: "film"))
    case "--paper":
        film.paper = resolveStock(take(), in: FilmSimData.papers, kind: "paper")
        film.negative = false                                     // an explicit paper means print
    case "--film-negative": film.negative = true
    case "--ev-film": film.evFilm = Float(take()) ?? film.evFilm
    case "--ev-paper": film.evPaper = Float(take())
    case "--couplers": film.couplers = Float(take()) ?? film.couplers
    case "--coupler-radius": film.couplersRadius = Float(take()) ?? film.couplersRadius
    case "--halation": film.halation = true
    case "--halation-strength": film.halationStrength = Float(take()) ?? film.halationStrength; film.halation = true
    case "--halation-radius": film.halationRadius = Float(take()) ?? film.halationRadius; film.halation = true
    case "--halation-midtones": film.halationMidtones = Float(take()) ?? film.halationMidtones; film.halation = true
    case "--no-grain": film.grain = false
    case "--grain-size": film.grainSize = Float(take()) ?? film.grainSize
    case "--denoise":
        // Optional mode value; a bare --denoise takes the traditional path.
        if i < args.count, let mode = DenoiseMode(rawValue: args[i].lowercased()) {
            i += 1
            options.denoise = mode
        } else {
            options.denoise = .wavelet
        }
    case "--denoise-strength":
        if let v = Float(take()) { options.denoiseStrength = v }
        if options.denoise == .off { options.denoise = .wavelet }
    case "--denoise-chroma":
        options.denoiseChroma = Float(take()) ?? options.denoiseChroma
        if options.denoise == .off { options.denoise = .wavelet }
    case "--denoise-model": options.denoiseModels.append(URL(fileURLWithPath: take())); options.denoise = .neural
    case "--denoise-time": options.denoiseTime = Float(take()) ?? options.denoiseTime; options.denoise = .neural
    case "--denoise-ensemble": options.denoiseEnsemble = true; options.denoise = .neural
    case "-j", "--jobs": jobsLimit = Int(take())
    case "-h", "--help": print(usage); exit(0)
    default:
        if a.hasPrefix("-") { fail("unknown option \(a)") }
        inputs.append(a)
    }
}

guard !inputs.isEmpty else { fail(usage) }
if formats.isEmpty { formats = [.jpeg] }
if filmEnabled { options.film = film }

// de-duplicate
var seen = Set<OutputFormat>()
formats = formats.filter { seen.insert($0).inserted }

let files = collectInputs(inputs)
guard !files.isEmpty else { fail("no input files found") }
if let outDir { try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true) }

let jobs = files.map { input -> FoveonJob in
    let dir = outDir ?? input.deletingLastPathComponent()
    let stem = input.deletingPathExtension().lastPathComponent
    let targets = formats.map { format in
        FoveonTarget(format, dir.appendingPathComponent(stem).appendingPathExtension(format.fileExtension))
    }
    return FoveonJob(input: input, targets: targets, options: options)
}

let developer = FoveonDeveloper()
let started = Date()
let results = await developer.process(jobs, maxConcurrent: jobsLimit)
let elapsed = Date().timeIntervalSince(started)

var failures = 0
for (job, result) in zip(jobs, results) {
    if case .failure(let error) = result {
        failures += 1
        FileHandle.standardError.write(Data("✗ \(job.input.lastPathComponent): \(error)\n".utf8))
    } else {
        print("✓ \(job.input.lastPathComponent)")
    }
}
let done = jobs.count - failures
print(String(format: "%d/%d in %.2fs (%.1f img/s)", done, jobs.count, elapsed, Double(done) / max(elapsed, 1e-6)))
exit(failures == 0 ? 0 : 1)
