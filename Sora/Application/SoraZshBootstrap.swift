import Foundation

/// Installs a Sora-owned `ZDOTDIR` that sources Ghostty's zsh integration,
/// then replaces the stock macOS `user@host` prompt.
enum SoraZshBootstrap {
    enum Error: Swift.Error, Equatable {
        case missingResource
        case writeFailed
    }

    /// Copies bundled zsh startup files into `directory`.
    @discardableResult
    static func install(
        into directory: URL,
        source: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try copyIfChanged(
            from: source,
            to: directory.appendingPathComponent(".zshenv"),
            fileManager: fileManager
        )
        let siblings = ["highlight.zsh", "command-blocks.zsh", "prompt-line.zsh"]
        for name in siblings {
            let sibling = source.deletingLastPathComponent().appendingPathComponent(name)
            if fileManager.fileExists(atPath: sibling.path) {
                try copyIfChanged(
                    from: sibling,
                    to: directory.appendingPathComponent(name),
                    fileManager: fileManager
                )
            }
        }
        return directory
    }

    private static func copyIfChanged(
        from source: URL,
        to destination: URL,
        fileManager: FileManager
    ) throws {
        let data = try Data(contentsOf: source)
        if (try? Data(contentsOf: destination)) != data {
            do {
                try data.write(to: destination, options: .atomic)
            } catch {
                throw Error.writeFailed
            }
        }
    }

    static func bundledSource(bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "zshenv", withExtension: nil, subdirectory: "zsh")
    }

    static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root
            .appendingPathComponent("Sora", isDirectory: true)
            .appendingPathComponent("zsh", isDirectory: true)
    }

    static func prepare(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let source = bundledSource(bundle: bundle) else {
            throw Error.missingResource
        }
        return try install(
            into: defaultDirectory(fileManager: fileManager),
            source: source,
            fileManager: fileManager
        )
    }
}
