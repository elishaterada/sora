import SwiftUI

struct SessionHeader: View {
    let workingDirectory: URL?

    var body: some View {
        HStack(spacing: 8) {
            badge(icon: "folder.fill", text: displayPath)
            if let branch {
                badge(icon: "arrow.triangle.branch", text: branch, tint: SoraTheme.git)
            }
        }
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

    private func badge(icon: String, text: String, tint: Color = SoraTheme.muted) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SoraTheme.text)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .soraGlass(in: Capsule())
        .accessibilityElement(children: .combine)
    }
}
