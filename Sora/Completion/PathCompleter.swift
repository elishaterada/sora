import Foundation

enum PathCompleter {
    struct Match: Equatable {
        var token: String
        var isDirectory: Bool
    }

    static func lastToken(in line: String) -> (head: String, token: String) {
        if let index = line.lastIndex(of: " ") {
            let tokenStart = line.index(after: index)
            return (String(line[..<tokenStart]), String(line[tokenStart...]))
        }
        return ("", line)
    }

    static func looksLikePath(_ token: String) -> Bool {
        if token.isEmpty { return false }
        if token.contains("/") { return true }
        if token.hasPrefix("~") { return true }
        if token.hasPrefix(".") { return true }
        return false
    }

    static func split(_ token: String) -> (directoryToken: String, prefix: String) {
        if token.hasSuffix("/") {
            return (token, "")
        }
        if let slash = token.lastIndex(of: "/") {
            let after = token.index(after: slash)
            return (String(token[...slash]), String(token[after...]))
        }
        return ("", token)
    }

    static func matches(
        token: String,
        cwd: URL,
        fileManager: FileManager = .default,
        limit: Int = 64
    ) -> [Match] {
        guard !token.isEmpty else { return [] }
        if token == "~" {
            return [Match(token: "~/", isDirectory: true)]
        }

        let (directoryToken, prefix) = split(token)
        let directory = expand(directoryToken.isEmpty ? "." : directoryToken, cwd: cwd)
        let options: FileManager.DirectoryEnumerationOptions = prefix.hasPrefix(".") ? [] : [.skipsHiddenFiles]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: options
        ) else {
            return []
        }

        let prefixFolded = prefix.lowercased()
        var matches: [Match] = []
        for url in urls {
            let name = url.lastPathComponent
            if !prefix.isEmpty, !name.lowercased().hasPrefix(prefixFolded) {
                continue
            }
            if prefix.isEmpty, name.hasPrefix(".") {
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            let isDirectory = values?.isDirectory == true
            let completed = directoryToken + name + (isDirectory ? "/" : "")
            matches.append(Match(token: completed, isDirectory: isDirectory))
        }

        matches.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            if lhs.token.count != rhs.token.count {
                return lhs.token.count < rhs.token.count
            }
            return lhs.token.localizedStandardCompare(rhs.token) == .orderedAscending
        }
        if matches.count > limit {
            return Array(matches.prefix(limit))
        }
        return matches
    }

    static func expand(_ token: String, cwd: URL) -> URL {
        if token.isEmpty || token == "." || token == "./" {
            return cwd
        }
        if token == "~" || token == "~/" {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        if token.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(token.dropFirst(2)), isDirectory: token.hasSuffix("/"))
        }
        if token.hasPrefix("/") {
            return URL(fileURLWithPath: token, isDirectory: token.hasSuffix("/"))
        }
        return cwd.appendingPathComponent(token, isDirectory: token.hasSuffix("/"))
    }
}
