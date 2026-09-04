import SwiftUI

struct CommandHistoryView: View {
    @ObservedObject var store: CommandHistoryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.recent.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(SoraTheme.copper)
                    Text("No recorded commands yet")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SoraTheme.text)
                    Text("Run a command in a terminal tab to see it here.")
                        .font(.system(size: 12))
                        .foregroundStyle(SoraTheme.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List(store.recent) { run in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(run.command)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(SoraTheme.text)
                            .lineLimit(2)
                        HStack(spacing: 8) {
                            Label(run.cwd.lastPathComponent, systemImage: "folder")
                            Spacer()
                            Text("exit \(run.exitCode)")
                                .foregroundStyle(run.exitCode == 0 ? SoraTheme.sage : Color(red: 0.82, green: 0.42, blue: 0.42))
                            Text(run.finishedAt, style: .time)
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(SoraTheme.muted)
                        .labelStyle(.titleAndIcon)
                    }
                    .padding(.vertical, 6)
                    .listRowBackground(SoraTheme.surface)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .background(SoraTheme.ink)
        .preferredColorScheme(.dark)
        .frame(minWidth: 420, minHeight: 240)
        .navigationTitle("History")
    }
}
