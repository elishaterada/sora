import AppKit
import CoreText
import SwiftUI

/// Semantic chrome tokens. Terminal ANSI colors live in `Resources/sora.ghostty`;
/// the values below mirror that file so SwiftUI chrome and Ghostty stay aligned.
enum SoraTheme {
    static func adaptive(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            NSColor(srgb: appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua ? light : dark)
        }
    }
    static var nsInputBackground: NSColor {
        adaptive(light: 0xF7F8FA, dark: 0x111111).withAlphaComponent(0.20)
    }

    // MARK: - Panda primitives (from sora.ghostty)

    /// `#292a2b`
    static let pandaBackground = Color(srgb: 0x292A2B)
    /// `#cccccc`
    static let pandaForeground = Color(srgb: 0xCCCCCC)
    /// `#19f9d8` — product accent for every Sora-drawn control.
    static let pandaTeal = Color(srgb: 0x19F9D8)
    /// `#ff2c6d`
    static let pandaPink = Color(srgb: 0xFF2C6D)
    /// `#ffb86c`
    static let pandaPeach = Color(srgb: 0xFFB86C)
    /// `#45a9f9`
    static let pandaBlue = Color(srgb: 0x45A9F9)

    // MARK: - Semantic color

    static let text = Color(nsColor: adaptive(light: 0x242833, dark: 0xCCCCCC))
    static let muted = Color.secondary
    static let git = Color.green
    /// Prefer this over `Color.accentColor` so identity is Panda, not System Settings.
    static let accent = Color(nsColor: nsAccent)
    /// High-stakes / full-access / destructive emphasis.
    static let warning = Color(nsColor: nsWarning)
    static let danger = Color(nsColor: adaptive(light: 0xB42349, dark: 0xFF2C6D))

    /// Inline code in agent answers. Distinct from teal links so a sentence
    /// mixing identifiers and links stays readable without background fills.
    static let codeInline = Color(nsColor: nsCodeInline)

    static let nsAccent = adaptive(light: 0x00796B, dark: 0x19F9D8)
    static let nsCodeInline = adaptive(light: 0x8A4B00, dark: 0xFFB86C)
    static let nsWarning = adaptive(light: 0x8A4B00, dark: 0xFFB86C)
    static var nsClear: NSColor { .clear }

    /// Near-clear window fill so AppKit composites glass; `.clear` skips blur.
    static var nsWindowFill: NSColor {
        NSColor.white.withAlphaComponent(0.001)
    }

    /// Window frost. Keep this lighter than a solid pane so the desktop shows through.
    static var nsGlassTint: NSColor {
        NSColor(calibratedWhite: TerminalPreferences.isLight ? 0.96 : 0.10, alpha: 0.65)
    }

    // MARK: - Elevation / hairline

    /// Single hairline value for chrome dividers and selected-row washes.
    static let hairline = Color.primary.opacity(0.08)
    static let hairlineStrong = Color.primary.opacity(0.10)
    static let fillSubtle = Color.primary.opacity(0.08)
    static let fillPanel = Color(nsColor: adaptive(light: 0xFFFFFF, dark: 0x000000)).opacity(0.75)
    static let fillDeep = Color(nsColor: adaptive(light: 0xF2F4F7, dark: 0x000000)).opacity(0.92)
    static let fillCode = Color.primary.opacity(0.07)
    static let fillCard = Color.primary.opacity(0.04)
    static let sidebarWash = Color.primary.opacity(0.04)

    // MARK: - Spacing (4pt grid)

    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16
    /// Matches `window-padding-x` in `sora.ghostty`.
    static var gridPaddingX: CGFloat { TerminalPreferences.compactSpacing ? 16 : 24 }
    /// Matches sticky / resume inset used next to the grid.
    static var chromeInset: CGFloat { gridPaddingX }

    // MARK: - Radius

    static let radiusSmall: CGFloat = 6
    static let radiusMedium: CGFloat = 8
    static let radiusLarge: CGFloat = 10

    // MARK: - Hit targets

    static let hitCompact: CGFloat = 28
    static let hitMinimum: CGFloat = 32

    // MARK: - Motion

    static let motionSidebar = Animation.easeInOut(duration: 0.18)
    static let motionCrossfade = Animation.easeInOut(duration: 0.12)
    static let motionFeedback = Animation.easeInOut(duration: 0.10)
    /// Frequent transcript growth should settle confidently without making
    /// each token feel like a fresh animation.
    static let motionStreamingScroll = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.20)

    // MARK: - Typography

    /// Live terminal / agent body size. Defaults match `sora.ghostty`; users can
    /// change it in Settings. Overlay chrome (13/11) stays fixed.
    static var terminalFontSize: CGFloat {
        TerminalPreferences.fontSize
    }

    static var terminalFont: NSFont {
        NSFontManager.shared.font(withFamily: TerminalPreferences.fontFamily, traits: [], weight: 5, size: terminalFontSize)
            ?? NSFont(name: "SFMono-Regular", size: terminalFontSize)
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
        let bold = NSFontManager.shared.convert(terminalFont, toHaveTrait: .boldFontMask)
        return Font(bold)
    }

    /// Secondary labels — rounded to the chrome 13pt scale (was 12.96).
    static var agentCaption: Font {
        .system(size: chromeSize, weight: .medium)
    }

    /// Tertiary labels — rounded to the chrome 11pt scale (was 11.52).
    static var agentCaption2: Font {
        .system(size: chromeCaptionSize, weight: .medium)
    }

    static let chromeSize: CGFloat = 13
    static let chromeCaptionSize: CGFloat = 11

    static var chromeBody: Font {
        .system(size: chromeSize, weight: .medium)
    }

    static var chromeBodySemibold: Font {
        .system(size: chromeSize, weight: .semibold)
    }

    static var chromeCaption: Font {
        .system(size: chromeCaptionSize, weight: .medium)
    }

    static var chromeCaptionSemibold: Font {
        .system(size: chromeCaptionSize, weight: .semibold)
    }

    static var chromeIcon: Font {
        .system(size: 12, weight: .medium)
    }

    static var chromeIconSmall: Font {
        .system(size: 11, weight: .semibold)
    }
}

// MARK: - Color helpers

private extension Color {
    init(srgb hex: UInt32, opacity: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

private extension NSColor {
    convenience init(srgb hex: UInt32, alpha: CGFloat = 1) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >> 8) & 0xFF) / 255
        let b = CGFloat(hex & 0xFF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: alpha)
    }
}

// MARK: - Chrome control style

/// Plain button with hover wash, pressed dim, and a visible focus ring.
struct SoraChromeButtonStyle: ButtonStyle {
    var fill: Color = .clear
    var pressedFill: Color = SoraTheme.fillSubtle
    var hoverFill: Color = SoraTheme.fillSubtle
    var cornerRadius: CGFloat = SoraTheme.radiusSmall

    func makeBody(configuration: Configuration) -> some View {
        SoraChromeButtonBody(
            configuration: configuration,
            fill: fill,
            pressedFill: pressedFill,
            hoverFill: hoverFill,
            cornerRadius: cornerRadius
        )
    }
}

private struct SoraChromeButtonBody: View {
    let configuration: ButtonStyle.Configuration
    var fill: Color
    var pressedFill: Color
    var hoverFill: Color
    var cornerRadius: CGFloat
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(SoraTheme.accent.opacity(isFocused ? 0.9 : 0), lineWidth: 1.5)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering = $0 }
            .animation(SoraTheme.motionFeedback, value: hovering)
            .animation(SoraTheme.motionFeedback, value: configuration.isPressed)
            .animation(SoraTheme.motionFeedback, value: isFocused)
    }

    private var background: Color {
        if configuration.isPressed { return pressedFill }
        if hovering { return hoverFill }
        return fill
    }
}
