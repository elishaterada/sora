import SwiftUI

/// Semantic chrome. Terminal colors live in `Resources/sora.ghostty`.
enum SoraTheme {
    static let text = Color.primary
    static let muted = Color.secondary
    static let git = Color.green
    static let accent = Color.accentColor

    static var nsClear: NSColor { .clear }
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
