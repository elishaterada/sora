import Foundation

/// Installs a Sora-owned `ZDOTDIR` that sources Ghostty's zsh integration,
/// then replaces the stock macOS `user@host` prompt.
enum SoraZshBootstrap {
    enum Error: Swift.Error, Equatable {
        case missingResource
        case writeFailed
    }

    /// Copies the bundled `zshenv` to `directory/.zshenv`.
    @discardableResult
    static func install(
        into directory: URL,
        source: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(".zshenv")
        let data = try Data(contentsOf: source)
        if (try? Data(contentsOf: destination)) != data {
            do {
                try data.write(to: destination, options: .atomic)
            } catch {
                throw Error.writeFailed
            }
        }
        return directory
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
