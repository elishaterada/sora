import SwiftUI

struct CommandHistoryView: View {
    @ObservedObject var store: CommandHistoryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.recent.isEmpty {
                Text("No recorded commands yet. Run a command in a terminal tab.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            } else {
                List(store.recent) { run in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(run.command)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(2)
                        HStack {
                            Text(run.cwd.path)
                                .lineLimit(1)
                            Spacer()
                            Text("exit \(run.exitCode)")
                            Text(run.finishedAt, style: .time)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 420, minHeight: 240)
        .navigationTitle("History")
    }
}
