import SwiftUI

struct SessionHeader: View {
    let workingDirectory: URL?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "folder")
                .font(.system(size: 10, weight: .medium))
            Text(displayPath)
                .lineLimit(1)
            if let branch {
                Text(branch)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .controlSize(.small)
        .help(displayPath)
        .accessibilityElement(children: .combine)
    }

    private var displayPath: String {
        guard let workingDirectory else { return "~" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = workingDirectory.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + String(path.dropFirst(home.count))
        }
        return workingDirectory.lastPathComponent
    }

    private var branch: String? {
        guard let workingDirectory else { return nil }
        return GitRepository.branchName(containing: workingDirectory)
    }
}
