import SwiftUI

struct SessionHeader: View {
    let workingDirectory: URL?

    var body: some View {
        HStack(spacing: 8) {
            badge(
                icon: "folder.fill",
                text: displayPath,
                tint: SoraTheme.copper
            )
            if let branch {
                badge(
                    icon: "arrow.triangle.branch",
                    text: branch,
                    tint: SoraTheme.sage
                )
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(SoraTheme.ink)
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

    private func badge(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 11, weight: .medium, design: .default))
                .foregroundStyle(SoraTheme.text)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(SoraTheme.surface)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(SoraTheme.hairline, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}
