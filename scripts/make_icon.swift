// Generates the 1024×1024 app icon with CoreGraphics (run on the macOS CI runner):
//   swift scripts/make_icon.swift CarLyrics/Assets.xcassets/AppIcon.appiconset/AppIcon.png
//
// Design: deep gradient (dark purple → warm amber), three lyric lines
// (middle one bright and bold, the others dimmed) and a small music note. No text.

import CoreGraphics
import Foundation
import ImageIO

let size = 1024
let S = CGFloat(size)
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"

let space = CGColorSpace(name: CGColorSpace.sRGB)!
// Opaque (no alpha), as iOS app icons require.
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    fatalError("Could not create context")
}
// Work in a top-left origin, y-down coordinate system.
ctx.translateBy(x: 0, y: S)
ctx.scaleBy(x: 1, y: -1)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

// 1. Diagonal gradient: dark purple (top-left) → warm amber (bottom-right).
let background = CGGradient(colorsSpace: space, colors: [
    rgb(0.07, 0.03, 0.14),
    rgb(0.17, 0.06, 0.26),
    rgb(0.32, 0.10, 0.28),
    rgb(0.62, 0.30, 0.13),
    rgb(0.82, 0.52, 0.18),
] as CFArray, locations: [0, 0.35, 0.6, 0.86, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: 0), end: CGPoint(x: S, y: S), options: [])

// 2. Soft amber glow from the bottom-right corner.
let glow = CGGradient(colorsSpace: space, colors: [
    rgb(1.0, 0.70, 0.30, 0.35), rgb(1.0, 0.70, 0.30, 0),
] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: S * 0.92, y: S * 0.95), startRadius: 0,
                       endCenter: CGPoint(x: S * 0.92, y: S * 0.95), endRadius: S * 0.7, options: [])

// 3. Gentle vignette to keep it moody.
let vignette = CGGradient(colorsSpace: space, colors: [
    rgb(0, 0, 0, 0), rgb(0, 0, 0, 0.35),
] as CFArray, locations: [0.55, 1])!
ctx.drawRadialGradient(vignette, startCenter: CGPoint(x: S / 2, y: S / 2), startRadius: 0,
                       endCenter: CGPoint(x: S / 2, y: S / 2), endRadius: S * 0.75, options: [.drawsAfterEndLocation])

// 4. Three lyric lines (pills).
func pill(x: CGFloat, centerY: CGFloat, width: CGFloat, height: CGFloat, color: CGColor) {
    let rect = CGRect(x: x, y: centerY - height / 2, width: width, height: height)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
    ctx.setFillColor(color)
    ctx.fillPath()
}

let left: CGFloat = 184
pill(x: left, centerY: 352, width: 460, height: 50, color: rgb(1, 1, 1, 0.34))
pill(x: left, centerY: 672, width: 392, height: 50, color: rgb(1, 1, 1, 0.34))

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 8), blur: 30, color: rgb(0, 0, 0, 0.45))
pill(x: left, centerY: 512, width: 656, height: 96, color: rgb(1, 1, 1, 1))
ctx.restoreGState()

// 5. Small music note (eighth note), top right, warm white.
let noteColor = rgb(1.0, 0.86, 0.62, 0.95)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 4), blur: 16, color: rgb(0, 0, 0, 0.35))
ctx.setFillColor(noteColor)
ctx.setStrokeColor(noteColor)

// Head: tilted ellipse.
ctx.saveGState()
ctx.translateBy(x: 772, y: 388)
ctx.rotate(by: -22 * .pi / 180)
ctx.fillEllipse(in: CGRect(x: -48, y: -34, width: 96, height: 68))
ctx.restoreGState()

// Stem.
ctx.fill(CGRect(x: 803, y: 232, width: 18, height: 156))

// Flag.
ctx.setLineWidth(18)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: 812, y: 240))
ctx.addCurve(to: CGPoint(x: 868, y: 338), control1: CGPoint(x: 830, y: 290), control2: CGPoint(x: 890, y: 288))
ctx.strokePath()
ctx.restoreGState()

// Write PNG.
guard let image = ctx.makeImage() else { fatalError("Could not render image") }
let url = URL(fileURLWithPath: outPath)
try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
    fatalError("Could not create PNG destination at \(outPath)")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("Could not write \(outPath)") }
print("Wrote \(outPath) (\(image.width)×\(image.height))")
