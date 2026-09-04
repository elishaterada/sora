import SwiftUI

/// Semantic chrome. Terminal colors live in `Resources/sora.ghostty`.
enum SoraTheme {
    static let text = Color.primary
    static let muted = Color.secondary
    static let git = Color.green
    static let accent = Color.accentColor

    static var nsClear: NSColor { .clear }

    /// Near-clear window fill so AppKit composites glass; `.clear` skips blur.
    static var nsWindowFill: NSColor {
        NSColor.white.withAlphaComponent(0.001)
    }

    /// Window frost. Keep this lighter than a solid pane so the desktop shows through.
    static var nsGlassTint: NSColor {
        NSColor(calibratedWhite: 0.10, alpha: 0.50)
    }
}
