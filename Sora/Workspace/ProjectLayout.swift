import Foundation

/// Reusable structure only. No terminal history, drafts, commands or Agent tasks.
struct ProjectLayout: Codable, Equatable, Identifiable {
    struct Tab: Codable, Equatable {
        var directory: String
        var name: String
    }
    let id: UUID
    var revision: UUID
    var name: String
    var tabs: [Tab]
    var selectedIndex: Int
    var splitIndices: [Int]
    var splitFraction: Double
    var paneLayout: PaneLayout<Int>?
    var hasSplit: Bool { paneLayout?.isSplit == true || !splitIndices.isEmpty }

    init(name: String, snapshot: WorkspaceSnapshot) throws {
        id = UUID()
        revision = UUID()
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        tabs = snapshot.directories.enumerated().map { index, directory in
            Tab(directory: directory, name: snapshot.tabNames.flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? "")
        }
        selectedIndex = snapshot.selectedIndex
        splitIndices = (snapshot.splitIDs ?? []).compactMap { snapshot.sessionIDs?.firstIndex(of: $0) }
        splitFraction = snapshot.splitFraction ?? 0.5
        if let tree = snapshot.restoredPaneLayout(), let ids = snapshot.sessionIDs {
            paneLayout = tree.mapLeaves { ids.firstIndex(of: $0)! }
        }
        try validate()
    }

    func validate() throws {
        guard !name.isEmpty, name.utf8.count <= 100,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw LayoutError.invalidName }
        guard (1...64).contains(tabs.count), tabs.indices.contains(selectedIndex),
              splitIndices.isEmpty || (splitIndices.count == 2 && Set(splitIndices).count == 2 && splitIndices.allSatisfy(tabs.indices.contains)),
              splitFraction.isFinite, (0.2...0.8).contains(splitFraction),
              tabs.allSatisfy({ ($0.directory.isEmpty || $0.directory.hasPrefix("/")) && $0.directory.utf8.count <= 4096
                  && !$0.directory.contains("\0") && $0.name.utf8.count <= 1024 }) else { throw LayoutError.invalidLayout }
        if let paneLayout, !paneLayout.isValid(allowed: Set(tabs.indices)) { throw LayoutError.invalidLayout }
    }

    func missingFolders(fileManager: FileManager = .default) -> [Int] {
        tabs.indices.filter { index in
            guard !tabs[index].directory.isEmpty else { return false }
            var isDirectory: ObjCBool = false
            return !fileManager.fileExists(atPath: tabs[index].directory, isDirectory: &isDirectory) || !isDirectory.boolValue
        }
    }

    func snapshot(replacements: [Int: URL] = [:], fileManager: FileManager = .default) throws -> WorkspaceSnapshot {
        try validate()
        var resolved = self
        for (index, url) in replacements {
            guard tabs.indices.contains(index), url.isFileURL else { throw LayoutError.invalidLayout }
            resolved.tabs[index].directory = url.path
        }
        try resolved.validate()
        let missing = resolved.missingFolders(fileManager: fileManager)
        guard missing.isEmpty else { throw LayoutError.missingFolders(missing.map { resolved.tabs[$0].directory }) }
        // Fresh UUIDs prevent templates from reopening archived input or sharing
        // a history/Agent identity with the source window or another opening.
        let ids = tabs.map { _ in UUID() }
        var snapshot = WorkspaceSnapshot(directories: resolved.tabs.map(\.directory), selectedIndex: selectedIndex,
            sessionIDs: ids, tabNames: tabs.map(\.name))
        snapshot.splitIDs = splitIndices.map { ids[$0] }
        snapshot.splitFraction = splitFraction
        snapshot.paneLayout = paneLayout?.mapLeaves { ids[$0] }
        return snapshot
    }

    enum LayoutError: LocalizedError {
        case invalidName, invalidLayout, duplicateName, changed, missingFolders([String]), unsupportedVersion, tooLarge
        var errorDescription: String? {
            switch self {
            case .invalidName: return "Use a layout name of 1–100 bytes without control characters."
            case .invalidLayout: return "This layout has invalid folders, tabs or pane settings. Layouts support up to 64 tabs."
            case .duplicateName: return "A project layout already uses that name. Choose another name."
            case .changed: return "This layout changed in another window or app. Refresh the list before trying again."
            case .missingFolders(let paths): return "These folders are unavailable:\n" + paths.joined(separator: "\n")
            case .unsupportedVersion: return "These layouts were saved by a newer Sora version. They have been left unchanged."
            case .tooLarge: return "The layout catalog is too large. Keep at most 50 saved layouts."
            }
        }
    }
}
