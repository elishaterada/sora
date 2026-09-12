import SwiftUI

struct ShellIntegrationView: View {
    @State private var status = ""
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Shell Integration").font(.title2.bold())
            Text("Add command blocks and folder context to an interactive Bash or zsh shell. Your shell keeps its own completion and keybindings.")
                .fixedSize(horizontal: false, vertical: true)
            GroupBox("On this Mac") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("New zsh tabs are ready automatically. For Bash or a nested zsh, copy the matching command and run it in that shell.")
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Copy Bash Setup") { copy("bash") }
                        Button("Copy zsh Setup") { copy("zsh") }
                    }
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Over SSH") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Export the scripts, copy the folder to your server, then follow its README. Setup runs only when you choose to source it; Sora never changes SSH or startup files for you.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Remote paths are display-only. Tab completes on the server. Agent runs in local tabs. Saved terminal output survives reconnecting, while a relaunch starts a fresh local shell.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Export Scripts for SSH…") { export() }
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Bash uses its visible Readline prompt. zsh can also mirror input below the output. Unsupported shells keep ordinary terminal behavior.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
            else if !status.isEmpty { Text(status).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
        }
        .padding(24).frame(minWidth: 600, idealWidth: 660, minHeight: 470)
    }

    private func copy(_ shell: String) {
        do {
            try SoraShellIntegration.prepare()
            GhosttyClipboard.writePlainText(SoraShellIntegration.activationCommand(shell: shell), to: .general)
            failure = nil
            status = "Copied. Paste into \(shell) and review it before pressing Return."
        } catch { failure = error.localizedDescription }
    }

    private func export() {
        let panel = NSOpenPanel()
        panel.title = "Choose Where to Export Shell Integration"
        panel.prompt = "Export Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        do {
            try SoraShellIntegration.prepare()
            let destination = parent.appendingPathComponent("sora-shell-integration", isDirectory: true)
            try SoraShellIntegration.export(to: destination)
            failure = nil
            status = "Exported to \(destination.path). Read README.txt before using it on a server."
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch { failure = "Could not export scripts: " + error.localizedDescription }
    }
}
