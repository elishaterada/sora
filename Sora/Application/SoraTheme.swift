import AppKit
import CoreText
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

    /// Matches `font-size` / `font-family` in `Resources/sora.ghostty`.
    static let terminalFontSize: CGFloat = 18

    static var terminalFont: NSFont {
        NSFont(name: "SFMono-Regular", size: terminalFontSize)
            ?? NSFont(name: "SF Mono", size: terminalFontSize)
            ?? NSFont.monospacedSystemFont(ofSize: terminalFontSize, weight: .regular)
    }

    static var terminalCTFont: CTFont {
        terminalFont
    }

    /// SwiftUI body text sized to match the Ghostty grid (18pt).
    static var agentBody: Font {
        .system(size: terminalFontSize)
    }

    static var agentBodySemibold: Font {
        .system(size: terminalFontSize, weight: .semibold)
    }

    /// Monospaced text at the same point size as the terminal.
    static var agentMono: Font {
        Font(terminalFont)
    }

    static var agentMonoSemibold: Font {
        let bold = NSFont(name: "SFMono-Semibold", size: terminalFontSize)
            ?? NSFont(name: "SF Mono", size: terminalFontSize)
            ?? NSFont.monospacedSystemFont(ofSize: terminalFontSize, weight: .semibold)
        return Font(bold)
    }

    /// Secondary labels ~70% of terminal size so chrome stays subordinate.
    static var agentCaption: Font {
        .system(size: terminalFontSize * 0.72, weight: .medium)
    }

    static var agentCaption2: Font {
        .system(size: terminalFontSize * 0.64, weight: .medium)
    }
}
