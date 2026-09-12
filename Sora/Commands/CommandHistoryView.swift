import SwiftUI

struct CommandHistoryView: View {
    @AppStorage(TerminalPreferences.appearanceKey) private var appearanceName = "dark"
    @ObservedObject var store: CommandHistoryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.recent.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(SoraTheme.accent)
                    Text("No recorded commands yet")
                        .font(.headline)
                    Text("Run a command in a terminal tab to see it here.")
                        .font(.subheadline)
                        .foregroundStyle(SoraTheme.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List(store.recent) { run in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(run.command)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(2)
                        HStack(spacing: 8) {
                            Label(run.cwd.lastPathComponent, systemImage: "folder")
                            Spacer()
                            Text("exit \(run.exitCode)")
                                .foregroundStyle(run.exitCode == 0 ? SoraTheme.git : Color.red)
                            Text(run.finishedAt, style: .time)
                        }
                        .font(.caption)
                        .foregroundStyle(SoraTheme.muted)
                        .labelStyle(.titleAndIcon)
                    }
                    .padding(.vertical, 4)
                    .contextMenu {
                        Button("Save Command…") {
                            SavedCommandEditor.present(command: run.command, directory: run.cwd, in: NSApp.keyWindow)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .preferredColorScheme(TerminalPreferences.Appearance(rawValue: appearanceName)?.colorScheme)
        .frame(minWidth: 420, minHeight: 240)
        .navigationTitle("History")
    }
}
