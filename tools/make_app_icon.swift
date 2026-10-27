import AppKit
import CoreGraphics
import Foundation

let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset"
let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]

func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func makeImage(pixels: Int) -> CGImage? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: pixels * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    let scale = CGFloat(pixels) / 1024
    context.scaleBy(x: scale, y: scale)
    context.setFillColor(NSColor(calibratedRed: 0.055, green: 0.095, blue: 0.16, alpha: 1).cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))

    let back = roundedRect(CGRect(x: 154, y: 206, width: 590, height: 466), radius: 78)
    context.setFillColor(NSColor(calibratedRed: 0.22, green: 0.48, blue: 0.62, alpha: 1).cgColor)
    context.addPath(back)
    context.fillPath()

    let front = roundedRect(CGRect(x: 286, y: 330, width: 584, height: 464), radius: 78)
    context.setFillColor(NSColor(calibratedRed: 0.25, green: 0.88, blue: 0.73, alpha: 1).cgColor)
    context.addPath(front)
    context.fillPath()

    context.setFillColor(NSColor(calibratedRed: 0.055, green: 0.095, blue: 0.16, alpha: 0.82).cgColor)
    context.fill(CGRect(x: 352, y: 430, width: 452, height: 26))
    context.fill(CGRect(x: 352, y: 500, width: 330, height: 26))
    context.fill(CGRect(x: 352, y: 570, width: 390, height: 26))
    return context.makeImage()
}

for item in sizes {
    guard let image = makeImage(pixels: item.pixels) else { continue }
    let representation = NSBitmapImageRep(cgImage: image)
    let data = representation.representation(using: .png, properties: [:])!
    try data.write(to: URL(fileURLWithPath: output).appendingPathComponent(item.name))
}
