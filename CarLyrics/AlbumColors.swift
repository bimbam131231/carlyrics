import UIKit

/// Extracts a background + accent color from album artwork.
/// The theme (LyricsTheme) later darkens them so the card stays dark and moody.
enum AlbumColors {
    static func extract(from image: UIImage) -> (background: String, accent: String)? {
        guard let cg = image.cgImage else { return nil }
        let size = 16
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: size * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard drawn else { return nil }

        var sum = RGB(r: 0, g: 0, b: 0)
        var vivid = RGB(r: 0, g: 0, b: 0)
        var vividScore = -1.0
        for i in 0..<(size * size) {
            let c = RGB(r: Double(pixels[i * 4]) / 255,
                        g: Double(pixels[i * 4 + 1]) / 255,
                        b: Double(pixels[i * 4 + 2]) / 255)
            sum = RGB(r: sum.r + c.r, g: sum.g + c.g, b: sum.b + c.b)
            let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b)
            let saturation = mx == 0 ? 0 : (mx - mn) / mx
            let score = saturation * (0.4 + 0.6 * mx) // vivid and not too dark
            if score > vividScore { vividScore = score; vivid = c }
        }
        let n = Double(size * size)
        let average = RGB(r: sum.r / n, g: sum.g / n, b: sum.b / n)
        // Average alone is muddy; pull it a bit toward the vivid color.
        let background = average.mixed(with: vivid, 0.3)
        return (background.hex, vivid.hex)
    }
}

@MainActor
final class AlbumColorLoader {
    private var cache: [URL: (background: String, accent: String)] = [:]

    func colors(for url: URL) async -> (background: String, accent: String)? {
        if let hit = cache[url] { return hit }
        guard let result = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: result.0),
              let colors = AlbumColors.extract(from: image) else { return nil }
        cache[url] = colors
        return colors
    }
}
