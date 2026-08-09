import AppKit
import SwiftUI

/// Centers an SF Symbol on its **ink** by measuring what SwiftUI actually draws.
///
/// Background is in `docs/research/sf-symbol-glyph-centering.md`. The short version: the send
/// button carried `.offset(x: -1, y: -1)`, eyeballed against a screenshot, and the note itself
/// said it wasn't a real fix. This replaces the guess with a measurement.
///
/// Two ways to measure, and only one of them is right:
///
/// - **Rasterizing `NSImage(systemSymbolName:)`** answers "is the ink centered inside the
///   symbol's *image* bounds". Tried first; it reported `arrow.up` at `(+0.25, 0)`. But
///   `Image(systemName:)` doesn't draw an image — it lays the symbol out as a glyph on a text
///   baseline, inside a line box built from the font's ascender and descender. Different box,
///   different answer.
/// - **Rasterizing the SwiftUI view itself** via `ImageRenderer` measures the real pipeline,
///   font metrics and all. That's what this does.
///
/// Measured that way, at 4× scale in a 42pt frame, every symbol Iris uses lands within
/// ±0.125pt of dead center — `arrow.up` included, at exactly `(0, 0)`. Which means the old
/// `-1, -1` wasn't correcting a glyph that sat low and right; it was *pushing* a centered
/// glyph up and left by a full point. Removing it is the fix, and this type is what proves
/// it rather than another screenshot.
///
/// Kept rather than deleted because it stays correct if a future symbol genuinely is
/// asymmetric, and because a computed zero is worth more than a hardcoded one.
@MainActor
enum SymbolInk {

    private struct Key: Hashable {
        let name: String
        let pointSize: CGFloat
        let weight: Font.Weight
        let side: CGFloat
    }

    private static var cache: [Key: CGSize] = [:]

    /// Below this, a correction is measurement noise rather than a real asymmetry, and
    /// applying it would only push the glyph onto a fractional pixel and blur it.
    private static let threshold: CGFloat = 0.25

    /// Translation, in points, that visually centers `name` inside a `side`×`side` frame.
    static func centeringOffset(_ name: String,
                                pointSize: CGFloat,
                                weight: Font.Weight = .regular,
                                side: CGFloat) -> CGSize {
        let key = Key(name: name, pointSize: pointSize, weight: weight, side: side)
        if let cached = cache[key] { return cached }
        let measured = measure(name, pointSize: pointSize, weight: weight, side: side)
            ?? .zero
        let snapped = CGSize(
            width: abs(measured.width) < threshold ? 0 : measured.width,
            height: abs(measured.height) < threshold ? 0 : measured.height)
        cache[key] = snapped
        return snapped
    }

    private static func measure(_ name: String,
                                pointSize: CGFloat,
                                weight: Font.Weight,
                                side: CGFloat) -> CGSize? {
        let content = Image(systemName: name)
            .font(.system(size: pointSize, weight: weight))
            .foregroundStyle(.white)
            .frame(width: side, height: side)

        let renderer = ImageRenderer(content: content)
        // 4×: a quarter-point of asymmetry is still a whole pixel to find.
        renderer.scale = 4
        guard let cg = renderer.cgImage else { return nil }

        let width = cg.width, height = cg.height
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = pixels.withUnsafeMutableBytes({ raw -> CGContext? in
            CGContext(data: raw.baseAddress,
                      width: width, height: height,
                      bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width, maxX = -1, minY = height, maxY = -1
        pixels.withUnsafeBytes { raw in
            for y in 0..<height {
                for x in 0..<width {
                    // Skip the antialiasing fringe: it's softer on some edges than others
                    // and would bias the box toward whichever side blurs more.
                    guard raw[(y * width + x) * 4 + 3] > 32 else { continue }
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }

        let scale = CGFloat(width) / side
        let inkCenterX = (CGFloat(minX) + CGFloat(maxX) + 1) / 2 / scale
        let inkCenterY = (CGFloat(minY) + CGFloat(maxY) + 1) / 2 / scale
        return CGSize(width: side / 2 - inkCenterX, height: side / 2 - inkCenterY)
    }
}

/// An SF Symbol centered on its measured ink, in a square frame.
///
/// Use this instead of `Image(systemName:).frame(...)` for any icon-only control, so the
/// centering claim is computed rather than assumed.
struct CenteredSymbol: View {
    let name: String
    let pointSize: CGFloat
    var weight: Font.Weight = .semibold
    let side: CGFloat

    var body: some View {
        let offset = SymbolInk.centeringOffset(
            name, pointSize: pointSize, weight: weight, side: side)
        Image(systemName: name)
            .font(.system(size: pointSize, weight: weight))
            .offset(x: offset.width, y: offset.height)
            .frame(width: side, height: side)
    }
}
