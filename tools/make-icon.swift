#!/usr/bin/env swift
//
// Generates Resources/AppIcon.icns from the app's own design tokens.
//
//   swift tools/make-icon.swift
//
// The mark is the concentric-ring motif from `GlassEmptyState` — the thing above Iris's name
// on an empty transcript — on the app's near-black background.
//
// Generated rather than exported from a screenshot on purpose. The source of that motif is
// three numbers in `DesignTokens.swift`; a PNG cropped out of a running window is a
// 312-pixel-wide copy of them that goes soft the moment it's scaled to 1024 and silently
// goes stale the moment the palette changes. This renders each icon size natively, so every
// one is crisp, and re-running it after a palette change regenerates a correct icon.

import AppKit
import SwiftUI

// MARK: - Tokens
//
// Mirrored from DesignTokens.swift rather than imported: this script builds standalone,
// outside the package, so it can be run without a full build.

let plateColor = Color(red: 0.02, green: 0.035, blue: 0.045)
/// `Tok.Palette.spectrum` — agent cyan, ice white, deeper cyan-teal. Same order, so the
/// icon's rings read in the same sequence as the ones in the window.
let spectrum: [Color] = [
    Color(red: 0.00, green: 0.95, blue: 1.00),
    Color(red: 0.88, green: 0.96, blue: 1.00),
    Color(red: 0.15, green: 0.70, blue: 0.78),
]

struct IconArtwork: View {
    /// Canvas edge in points. Every dimension below is a fraction of it, so the artwork is
    /// resolution-independent and each size is rendered rather than resampled.
    let side: CGFloat

    /// macOS icons sit in a rounded square inset from the canvas — roughly 824pt of 1024,
    /// with a continuous corner radius about 22.4% of that square.
    private var inset: CGFloat { side * 0.086 }
    private var plate: CGFloat { side - inset * 2 }
    private var corner: CGFloat { plate * 0.2237 }

    /// Ring diameters keep the app's 34 / 47 / 60 proportions, with the outer ring at just
    /// over half the plate so the mark has room to breathe.
    private var outer: CGFloat { plate * 0.52 }
    private func diameter(_ index: Int) -> CGFloat {
        outer * [34.0, 47.0, 60.0][index] / 60.0
    }

    /// A touch heavier than the app's 1.5pt hairline — a stroke that reads correctly at
    /// window scale disappears in a Dock icon. Floored at a full point so 16pt and 32pt
    /// still show three rings instead of a grey smudge.
    private var stroke: CGFloat { max(outer * 0.038, 1) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(plateColor)
                // The window's backdrop is a slow spectral wash, not flat black. A hint of
                // it keeps the icon from looking like a hole punched in the Dock.
                .overlay {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill(
                            RadialGradient(
                                colors: [spectrum[2].opacity(0.16), .clear],
                                center: .center,
                                startRadius: 0,
                                endRadius: plate * 0.62)
                        )
                }
                .frame(width: plate, height: plate)

            ForEach(Array(spectrum.enumerated()), id: \.offset) { index, color in
                Circle()
                    .strokeBorder(color.opacity(0.78), lineWidth: stroke)
                    .frame(width: diameter(index), height: diameter(index))
            }
        }
        .frame(width: side, height: side)
    }
}

// MARK: - Render

@MainActor
func render(side: CGFloat, scale: CGFloat) -> Data? {
    let renderer = ImageRenderer(content: IconArtwork(side: side))
    renderer.scale = scale
    guard let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return nil }
    // The renderer hands back a `side`-point image; stamp the real pixel dimensions so the
    // PNG is 2x where the iconset expects 2x.
    rep.size = NSSize(width: side, height: side)
    return rep.representation(using: .png, properties: [:])
}

MainActor.assumeIsolated {
    let arguments = CommandLine.arguments
    let outputDirectory = arguments.count > 1 ? arguments[1] : "Resources"
    let iconset = (outputDirectory as NSString).appendingPathComponent("Iris.iconset")

    try? FileManager.default.createDirectory(
        atPath: iconset, withIntermediateDirectories: true)

    // The exact set `iconutil` expects.
    let variants: [(name: String, side: CGFloat, scale: CGFloat)] = [
        ("icon_16x16", 16, 1), ("icon_16x16@2x", 16, 2),
        ("icon_32x32", 32, 1), ("icon_32x32@2x", 32, 2),
        ("icon_128x128", 128, 1), ("icon_128x128@2x", 128, 2),
        ("icon_256x256", 256, 1), ("icon_256x256@2x", 256, 2),
        ("icon_512x512", 512, 1), ("icon_512x512@2x", 512, 2),
    ]

    for variant in variants {
        guard let data = render(side: variant.side, scale: variant.scale) else {
            FileHandle.standardError.write(Data("failed to render \(variant.name)\n".utf8))
            exit(1)
        }
        let path = (iconset as NSString).appendingPathComponent("\(variant.name).png")
        try? data.write(to: URL(fileURLWithPath: path))
    }

    print("wrote \(variants.count) sizes to \(iconset)")
}
