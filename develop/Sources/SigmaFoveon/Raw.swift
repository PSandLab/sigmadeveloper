import CFoveonRaw
import Foundation

enum RawMode: UInt32 {
    case dng = 0
    case tiffLinearF16 = 1
    case tiffProxyHalf = 2
}

struct RawRender {
    let data: Data
    let width: Int
    let height: Int
    let orientation: Int
    let spatialGain: Bool
    let monoWeights: SIMD3<Float>
    let lens: LensShot?
    let iso: Float
}

public enum FoveonError: Error, CustomStringConvertible {
    case decode(code: Int32)
    case badInput(String)
    case render(String)

    public var description: String {
        switch self {
        case .decode(let c): return "x3f decode failed (code \(c))"
        case .badInput(let m): return "invalid input: \(m)"
        case .render(let m): return "render failed: \(m)"
        }
    }
}

/// Wrap an FFI result (owned bytes + info) as RawRender
private func rawRender(_ out: FoveonBytes, _ info: FoveonInfo, code: Int32) throws -> RawRender {
    guard code == 0, let ptr = out.ptr else { throw FoveonError.decode(code: code) }
    let data = Data(
        bytesNoCopy: UnsafeMutableRawPointer(ptr), count: out.len,
        deallocator: .custom { _, _ in foveon_bytes_free(out) })

    return RawRender(
        data: data, width: Int(info.width), height: Int(info.height),
        orientation: Int(info.orientation), spatialGain: info.spatial_gain != 0,
        monoWeights: SIMD3<Float>(info.mono_weights.0, info.mono_weights.1, info.mono_weights.2),
        lens: LensShot(info), iso: info.iso)
}

/// Decode `.x3f` bytes to DNG or developed-TIFF bytes via Rust core (one-shot)
func renderX3F(_ x3f: Data, mode: RawMode, whiteBalance: String?) throws -> RawRender {
    guard !x3f.isEmpty else { throw FoveonError.badInput("empty x3f data") }

    var out = FoveonBytes()
    var info = FoveonInfo()
    let code: Int32 = x3f.withUnsafeBytes { buf in
        let base = buf.bindMemory(to: UInt8.self).baseAddress
        let render = { (wb: UnsafePointer<CChar>?) in
            foveon_render(base, buf.count, mode.rawValue, wb, &out, &info)
        }
        return whiteBalance.map { wb in wb.withCString(render) } ?? render(nil)
    }
    return try rawRender(out, info, code: code)
}

/// Decode
final class RawDecoder {
    private let handle: OpaquePointer

    init(x3f: Data, whiteBalance: String? = nil) throws {
        guard !x3f.isEmpty else { throw FoveonError.badInput("empty x3f data") }
        let handle: OpaquePointer? = x3f.withUnsafeBytes { buf in
            let base = buf.bindMemory(to: UInt8.self).baseAddress
            let open = { (wb: UnsafePointer<CChar>?) in foveon_open(base, buf.count, wb) }
            return whiteBalance.map { wb in wb.withCString(open) } ?? open(nil)
        }
        guard let handle else { throw FoveonError.decode(code: -4) }
        self.handle = handle
    }

    deinit { foveon_close(handle) }

    func render(mode: RawMode) throws -> RawRender {
        var out = FoveonBytes()
        var info = FoveonInfo()
        let code = foveon_emit(handle, mode.rawValue, &out, &info)
        return try rawRender(out, info, code: code)
    }
}
