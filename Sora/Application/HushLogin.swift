import Foundation

/// Ghostty launches macOS sessions through `login(1)`, which prints
/// "Last login: …" unless `~/.hushlogin` exists.
enum HushLogin {
    enum Error: Swift.Error, Equatable {
        case createFailed(String)
    }

    static func ensure(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws {
        let url = home.appendingPathComponent(".hushlogin")
        if fileManager.fileExists(atPath: url.path) {
            return
        }
        guard fileManager.createFile(atPath: url.path, contents: Data()) else {
            throw Error.createFailed(url.path)
        }
    }
}
