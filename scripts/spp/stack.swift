import AppKit
import CoreGraphics
import Foundation

// Vertically stack input images into one contact sheet, scaled to a common width.
// Usage: swift stack.swift <outPath> <width> <img1> <img2> ...
let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write("usage: stack.swift <out> <width> <img...>\n".data(using: .utf8)!)
    exit(2)
}
let outPath = args[1]
let width = Int(args[2]) ?? 1400
let paths = Array(args.dropFirst(3))

var images: [CGImage] = []
for p in paths {
    guard let img = NSImage(contentsOfFile: p),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
    images.append(cg)
}
guard !images.isEmpty else { exit(1) }

let scaled = images.map { img -> (CGImage, Int) in
    let h = Int(Double(img.height) * Double(width) / Double(img.width))
    return (img, h)
}
let gap = 8
let totalH = scaled.reduce(0) { $0 + $1.1 } + gap * (scaled.count - 1)

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: width, height: totalH, bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: width, height: totalH))

var y = totalH
for (img, h) in scaled {
    y -= h
    ctx.draw(img, in: CGRect(x: 0, y: y, width: width, height: h))
    y -= gap
}

guard let out = ctx.makeImage() else { exit(1) }
let url = URL(fileURLWithPath: outPath)
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dest, out, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
CGImageDestinationFinalize(dest)
FileHandle.standardError.write("wrote \(outPath)\n".data(using: .utf8)!)
