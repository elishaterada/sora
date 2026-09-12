import Foundation

/// Installs only app-owned helpers. Export produces a reviewable source folder;
/// it never connects to a host or edits the user's shell/SSH startup files.
enum SoraShellIntegration {
    static var directory: URL { SoraZshBootstrap.defaultDirectory().deletingLastPathComponent().appendingPathComponent("Shell", isDirectory: true) }
    static let adapterFiles = ["sora.bash", "sora.zsh", "README.txt", "COPYING-GPL-3.0.txt", "bash-preexec-LICENSE.txt"]
    static let zshFiles = ["prompt-line.zsh", "highlight.zsh", "command-blocks.zsh"]
    static let ghosttyFiles = ["bash/ghostty.bash", "bash/bash-preexec.sh", "zsh/ghostty-integration"]

    static func prepare(bundle: Bundle = .main) throws {
        guard let source = bundle.resourceURL?.appendingPathComponent("shell-integration"),
              let zsh = bundle.resourceURL?.appendingPathComponent("zsh") else { throw CocoaError(.fileNoSuchFile) }
        try install(into: directory, source: source, zsh: zsh)
    }

    static func install(into destination: URL, source: URL, zsh: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination.appendingPathComponent("zsh"), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        for (base, names, subdirectory) in [(source, adapterFiles, ""), (zsh, zshFiles, "zsh/")] {
            for name in names {
                let data = try Data(contentsOf: base.appendingPathComponent(name))
                let target = destination.appendingPathComponent(subdirectory + name)
                if (try? Data(contentsOf: target)) != data { try data.write(to: target, options: .atomic) }
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            }
        }
    }

    static func activationCommand(shell: String, directory: URL = directory) -> String {
        let name = shell == "bash" ? "sora.bash" : "sora.zsh"
        let path = directory.appendingPathComponent(name).path
        return "source '" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func export(to destination: URL, installed: URL = directory, ghostty: URL? = Bundle.main.resourceURL?.appendingPathComponent("ghostty/shell-integration")) throws {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
        guard let ghostty else { throw CocoaError(.fileNoSuchFile) }
        // Assemble alongside the destination, then rename only when complete.
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".sora-shell-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: staging) }
        try install(into: staging, source: installed, zsh: installed.appendingPathComponent("zsh"))
        for name in ghosttyFiles {
            let target = staging.appendingPathComponent("ghostty/" + name)
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try manager.copyItem(at: ghostty.appendingPathComponent(name), to: target)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        }
        try manager.moveItem(at: staging, to: destination)
    }
}
