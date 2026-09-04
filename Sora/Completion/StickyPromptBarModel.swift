import Foundation

enum StickyPromptBarModel {
    /// Scrollbar is pinned to the live prompt when the viewport ends at `total`.
    static func isViewingLivePrompt(total: UInt64, offset: UInt64, len: UInt64) -> Bool {
        total == 0 || offset + len >= total
    }

    static func displayPath(for url: URL?) -> String {
        guard let url else { return "~" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + String(path.dropFirst(home.count))
        }
        return url.lastPathComponent
    }
}
