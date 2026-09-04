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
}
