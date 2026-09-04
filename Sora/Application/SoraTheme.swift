import SwiftUI

/// Semantic chrome. Terminal colors live in `Resources/sora.ghostty`.
enum SoraTheme {
    static let text = Color.primary
    static let muted = Color.secondary
    static let git = Color.green
    static let accent = Color.accentColor
    static let terminalCornerRadius: CGFloat = 12

    static var nsClear: NSColor { .clear }

    /// Near-clear window fill so AppKit composites glass; `.clear` skips blur.
    static var nsWindowFill: NSColor {
        NSColor.white.withAlphaComponent(0.001)
    }

    /// Dark tint so 18pt glyphs stay readable over wallpaper.
    static var nsGlassTint: NSColor {
        NSColor(calibratedWhite: 0.08, alpha: 0.78)
    }
}

extension View {
    @ViewBuilder
    func soraGlass<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
    }
}
