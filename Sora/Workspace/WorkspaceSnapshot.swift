import Foundation

/// Disk-safe tab list. Paths only — PTYs and scrollback are not restored.
struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    /// Empty string means the default shell working directory.
    var directories: [String]
    var selectedIndex: Int

    static let empty = WorkspaceSnapshot(directories: [""], selectedIndex: 0)

    init(directories: [String], selectedIndex: Int) {
        let dirs = directories.isEmpty ? [""] : directories
        self.directories = dirs
        self.selectedIndex = min(max(0, selectedIndex), dirs.count - 1)
    }
}
