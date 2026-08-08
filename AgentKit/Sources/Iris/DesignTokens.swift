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
        static let transcript: CGFloat = 26
        /// Deliberately 0: the composer field and send button must read as two controls.
        static let composer: CGFloat = 0
        static let status: CGFloat = 0
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

    enum Palette {
        static let user = Color(red: 0.42, green: 0.62, blue: 1.00)      // cool blue
        static let agent = Color(red: 0.72, green: 0.52, blue: 1.00)     // iris violet
        static let tool = Color(red: 0.36, green: 0.80, blue: 0.82)      // cyan
        static let approve = Color(red: 0.36, green: 0.84, blue: 0.60)   // green
        static let warn = Color(red: 1.00, green: 0.68, blue: 0.30)      // amber
        static let danger = Color(red: 1.00, green: 0.42, blue: 0.44)    // red

        /// Spectral sweep used by the streaming shimmer.
        static let spectrum: [Color] = [user, agent, tool]
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
