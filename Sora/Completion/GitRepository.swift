import Foundation

enum GitRepository {
    /// Walks from `url` toward `/` looking for a `.git` file or directory.
    static func root(containing url: URL, fileManager: FileManager = .default) -> URL? {
        var directory = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            directory = directory.deletingLastPathComponent().standardizedFileURL
        }

        var hops = 0
        while hops < 64 {
            hops += 1
            let git = directory.appendingPathComponent(".git")
            if fileManager.fileExists(atPath: git.path) {
                return directory
            }
            if directory.path == "/" {
                return nil
            }
            // Directory URLs make `deletingLastPathComponent()` of `/` yield `/..`.
            // Standardize or the walk never terminates and allocates without bound.
            let parent = directory.deletingLastPathComponent().standardizedFileURL
            if parent.path == directory.path {
                return nil
            }
            directory = parent
        }
        return nil
    }

    static func isInside(_ url: URL, root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    static func branchName(containing url: URL?, fileManager: FileManager = .default) -> String? {
        guard let url else { return nil }
        guard let gitDir = gitDirectory(containing: url, fileManager: fileManager) else { return nil }
        let headURL = gitDir.appendingPathComponent("HEAD")
        guard let raw = try? String(contentsOf: headURL, encoding: .utf8) else { return nil }
        let head = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.hasPrefix("ref:") {
            let ref = head.dropFirst(4).trimmingCharacters(in: .whitespaces)
            return URL(fileURLWithPath: ref).lastPathComponent
        }
        if head.count >= 7 {
            return String(head.prefix(7))
        }
        return nil
    }

    private static func gitDirectory(containing url: URL, fileManager: FileManager) -> URL? {
        guard let root = root(containing: url, fileManager: fileManager) else { return nil }
        let git = root.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: git.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue {
            return git
        }
        guard let text = try? String(contentsOf: git, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("gitdir:") else { continue }
            let rest = trimmed.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("/") {
                return URL(fileURLWithPath: rest)
            }
            return root.appendingPathComponent(rest)
        }
        return nil
    }
}
