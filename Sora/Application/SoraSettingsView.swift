import SwiftUI

/// macOS Settings → Sora. Font size pushes live into every Ghostty surface.
struct SoraSettingsView: View {
    @State private var fontSize = TerminalPreferences.fontSize

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Font Size")
                    Spacer()
                    Text("\(Int(fontSize)) pt")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: $fontSize,
                    in: TerminalPreferences.minimumFontSize...TerminalPreferences.maximumFontSize,
                    step: 1
                ) {
                    Text("Font Size")
                } minimumValueLabel: {
                    Text("\(Int(TerminalPreferences.minimumFontSize))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("\(Int(TerminalPreferences.maximumFontSize))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .onChange(of: fontSize) { newValue in
                    TerminalPreferences.fontSize = newValue
                }
                Button("Reset to Default (\(Int(TerminalPreferences.defaultFontSize)) pt)") {
                    fontSize = TerminalPreferences.defaultFontSize
                    TerminalPreferences.fontSize = TerminalPreferences.defaultFontSize
                }
            } header: {
                Text("Terminal")
            } footer: {
                Text("Applies to the Ghostty grid and Agent body text. Chrome labels stay at 11–13 pt.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 180)
        .onAppear { fontSize = TerminalPreferences.fontSize }
    }
}
