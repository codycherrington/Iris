import SwiftUI

/// Every spacing value, radius, glass variant, and timing curve in Iris.
///
/// Single source of truth on purpose: the look should be tunable from one file rather than
/// by hunting through views. If you're about to hard-code a number in a view, add it here
/// instead.
enum Tok {

    // MARK: Rhythm

    enum Space {
        static let hair: CGFloat = 2
        static let tight: CGFloat = 6
        static let snug: CGFloat = 10
        static let base: CGFloat = 14
        static let loose: CGFloat = 20
        static let wide: CGFloat = 28
    }

    enum Radius {
        static let chip: CGFloat = 8
        static let card: CGFloat = 14
        static let panel: CGFloat = 20
        /// Composer and other capsule-shaped surfaces.
        static let capsule: CGFloat = 22
    }

    /// Distance within which sibling glass shapes fuse inside a GlassEffectContainer.
    /// This is the knob that controls how "liquid" the UI reads — raise it and neighbours
    /// merge sooner.
    ///
    /// Careful: this applies to *every* sibling pair in the container, not just ones sharing
    /// a union id. A value larger than the gap between two controls will silently blend them
    /// into one blob — which is what made the send button look welded to the composer.
    enum Fusion {
        /// Deliberately 0. A message turn is now three stacked bubbles — thinking, actions,
        /// output — and at any non-zero value the neighbouring ones weld into a single blob
        /// with a glass tail between them, which defeats the whole point of separating them.
        static let transcript: CGFloat = 0
        /// Deliberately 0: the composer field and send button must read as two controls.
        static let composer: CGFloat = 0
        static let status: CGFloat = 0
        /// Also 0, for the same reason as the transcript: stacked tool cards that fuse read
        /// as one undifferentiated slab, and the panel's whole job is to keep them separate.
        static let sidebar: CGFloat = 0
    }

    // MARK: Glass

    enum Surface {
        static var panel: Glass { .regular }
        static var interactive: Glass { .regular.interactive() }
        static func accent(_ color: Color) -> Glass { .regular.tint(color) }
        static func accentInteractive(_ color: Color) -> Glass {
            .regular.tint(color).interactive()
        }
    }

    // MARK: Palette
    //
    // Iris = aperture + the rainbow messenger. Refraction is the theme, so the accents are a
    // narrow spectral sweep rather than arbitrary hues, and glass tints stay low-saturation —
    // Liquid Glass already saturates whatever sits behind it.
    //
    // Committed to a single dark look (see `preferredColorScheme(.dark)` in IrisApp) rather
    // than following system appearance: near-black base, neon cyan for the agent/primary
    // accent, ice white for the user/ambient accent. `background` is deliberately not pure
    // #000 — flat black gives Liquid Glass nothing to refract, so it carries a hair of blue.

    enum Palette {
        static let background = Color(red: 0.02, green: 0.035, blue: 0.045)

        static let user = Color(red: 0.88, green: 0.96, blue: 1.00)      // ice white
        static let agent = Color(red: 0.00, green: 0.95, blue: 1.00)     // neon cyan
        static let tool = Color(red: 0.15, green: 0.70, blue: 0.78)      // deeper cyan-teal
        static let approve = Color(red: 0.35, green: 0.95, blue: 0.70)   // mint (reads "success")
        static let warn = Color(red: 1.00, green: 0.72, blue: 0.32)      // amber
        static let danger = Color(red: 1.00, green: 0.38, blue: 0.42)    // red

        /// Spectral sweep used by the streaming shimmer, empty-state rings, and the backdrop
        /// blobs. Cyan → ice white → teal, so the drift stays inside the theme instead of
        /// reading as a rainbow.
        static let spectrum: [Color] = [agent, user, tool]
    }

    // MARK: Motion
    //
    // Springs only — no linear easing anywhere. Glass that moves linearly reads as a video
    // overlay rather than a material.

    enum Motion {
        /// Default for glass shape changes.
        static let glass = Animation.spring(response: 0.38, dampingFraction: 0.78)
        /// Snappier, for direct manipulation.
        static let touch = Animation.spring(response: 0.24, dampingFraction: 0.82)
        /// Slower, for entering/leaving content.
        static let content = Animation.spring(response: 0.46, dampingFraction: 0.85)
        /// Continuous ambient loop (shimmer, breathing).
        static let ambient = Animation.easeInOut(duration: 2.4).repeatForever(autoreverses: true)

        /// Resolve an animation against Reduce Motion. Glass morphing is exactly the kind of
        /// motion that needs an honest reduced path, not a shortened one.
        static func resolved(_ animation: Animation, reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : animation
        }
    }

    enum TypeScale {
        static let label = Font.system(size: 11, weight: .medium)
        static let mono = Font.system(size: 11.5, design: .monospaced)
        static let body = Font.system(size: 13.5)
        static let title = Font.system(size: 15, weight: .semibold)
    }
}

// MARK: - Namespaces

/// Identifiers for `glassEffectID` / `glassEffectUnion`. Shapes sharing a union id inside one
/// container fuse into a single blob and morph together.
enum GlassID {
    static let composer = "composer"
    static let sendButton = "send"
    static let statusBar = "status"
    static func message(_ id: UUID) -> String { "msg-\(id)" }
    static func tool(_ id: String) -> String { "tool-\(id)" }
    /// Union id shared by the composer capsule and its send button so they read as one
    /// piece of liquid rather than two adjacent controls.
    static let composerCluster = "composer-cluster"
}
