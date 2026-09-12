import Foundation

struct CommandCompletionRequest: Equatable {
    enum Kind: Equatable { case gitCommands, branches, scripts, flags(String) }
    let line: String
    let directory: URL
    let head: String
    let prefix: String
    let kind: Kind

    /// Complex shell syntax and aliases belong to the shell's own completer.
    static func parse(line: String, directory: URL) -> Self? {
        guard !line.isEmpty, line.utf8.count <= 4096,
              !line.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !line.contains(where: { "'\"\\$`;|&()<>".contains($0) }) else { return nil }
        var words = line.split(separator: " ").map(String.init)
        if line.hasSuffix(" ") { words.append("") }
        guard words.count >= 2 else { return nil }
        let prefix = words.last!
        let head = String(line.dropLast(prefix.count))
        let kind: Kind
        if words[0] == "git", words.count == 2 { kind = .gitCommands }
        else if prefix.hasPrefix("-") {
            let key = words[0] == "git" && words.count >= 3 ? "git " + words[1] : words[0]
            guard CommandCompletionEngine.flags[key] != nil else { return nil }
            kind = .flags(key)
        } else if words[0] == "git", words.count == 3,
                  ["switch", "checkout", "merge", "rebase"].contains(words[1]) { kind = .branches }
        else if ["npm", "pnpm", "yarn", "bun"].contains(words[0]), words.count == 3, words[1] == "run" { kind = .scripts }
        else { return nil }
        return Self(line: line, directory: directory, head: head, prefix: prefix, kind: kind)
    }
}

struct CommandCompletionChoice: Equatable {
    let value: String
    let detail: String

    func inserting(into request: CommandCompletionRequest) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./-=")
        let token = value.unicodeScalars.allSatisfy(safe.contains) ? value
            : "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return request.head + token + (value.hasSuffix("=") ? "" : " ")
    }
}

enum CommandCompletionEngine {
    typealias Choice = CommandCompletionChoice
    static let flags: [String: [Choice]] = [
        "git status": choices([("--short", "Compact status"), ("--branch", "Show branch information"), ("--ignored", "Include ignored files"), ("--untracked-files=", "Choose how to show untracked files")]),
        "git diff": choices([("--staged", "Compare staged changes"), ("--stat", "Show change statistics"), ("--name-only", "List changed paths"), ("--word-diff", "Highlight changed words")]),
        "git log": choices([("--oneline", "One line per commit"), ("--graph", "Draw the commit graph"), ("--all", "Include all refs"), ("--decorate", "Show branch and tag names"), ("--max-count=", "Limit the number of commits")]),
        "git commit": choices([("--message=", "Set the commit message"), ("--amend", "Replace the previous commit"), ("--no-edit", "Keep the existing commit message")]),
        "git switch": choices([("--create", "Create a new branch"), ("--detach", "Switch to a detached HEAD")]),
        "git checkout": choices([("--detach", "Check out a detached HEAD"), ("--patch", "Interactively select changes")]),
        "ls": choices([("-a", "Include hidden files"), ("-l", "Use the long listing format"), ("-h", "Show readable sizes with -l"), ("-t", "Sort by modification time"), ("-r", "Reverse the sort order")]),
        "rg": choices([("--hidden", "Search hidden files"), ("--ignore-case", "Ignore letter case"), ("--fixed-strings", "Treat patterns literally"), ("--files", "List files to search"), ("--glob", "Include or exclude matching paths"), ("--context", "Show surrounding lines")]),
        "curl": choices([("--head", "Request headers only"), ("--location", "Follow redirects"), ("--fail", "Fail on HTTP errors"), ("--silent", "Hide progress output"), ("--show-error", "Show errors in silent mode"), ("--output", "Write the response to a file")]),
        "npm": choices([("--help", "Show help"), ("--version", "Show the installed version"), ("--workspace", "Select a workspace"), ("--silent", "Reduce logging")]),
        "pnpm": choices([("--help", "Show help"), ("--version", "Show the installed version"), ("--filter", "Select workspace packages")]),
        "yarn": choices([("--help", "Show help"), ("--version", "Show the installed version")]),
        "bun": choices([("--help", "Show help"), ("--version", "Show the installed version")])
    ]
    private static func choices(_ values: [(String, String)]) -> [Choice] { values.map { Choice(value: $0.0, detail: $0.1) } }
    private static let gitCommands = choices([
        ("status", "Show changed files"), ("diff", "Inspect changes"), ("log", "Browse commit history"),
        ("add", "Stage changes"), ("commit", "Record staged changes"), ("switch", "Switch branches"),
        ("checkout", "Switch branches or restore files"), ("branch", "Manage branches"),
        ("merge", "Combine histories"), ("rebase", "Reapply commits"), ("fetch", "Download refs and objects"),
        ("pull", "Fetch and integrate changes"), ("push", "Publish commits")
    ])

    static func lookup(_ request: CommandCompletionRequest, limit: Int = 80) throws -> [Choice] {
        let values: [Choice]
        switch request.kind {
        case .gitCommands: values = gitCommands
        case .flags(let key): values = flags[key] ?? []
        case .branches: values = try branches(in: request.directory).map { Choice(value: $0, detail: "Local branch") }
        case .scripts: values = try scripts(in: request.directory)
        }
        return Array(values.filter { $0.value.hasPrefix(request.prefix) }
            .sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }.prefix(max(0, min(80, limit))))
    }

    private static func branches(in directory: URL) throws -> Set<String> {
        guard var git = GitRepository.gitDirectory(containing: directory, fileManager: .default) else { return [] }
        if let data = try read(git.appendingPathComponent("commondir"), limit: 4096) {
            let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            git = path.hasPrefix("/") ? URL(fileURLWithPath: path) : git.appendingPathComponent(path).standardizedFileURL
        }
        var names = Set<String>()
        // URL enumeration resolves macOS aliases such as /tmp → /private/tmp.
        // Normalize the root too before deriving relative branch names.
        let heads = git.appendingPathComponent("refs/heads", isDirectory: true).resolvingSymlinksInPath()
        if let enumerator = FileManager.default.enumerator(at: heads, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
            var scanned = 0
            while let url = enumerator.nextObject() as? URL, scanned < 10_000 {
                scanned += 1
                let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if info.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                if info.isRegularFile == true {
                    let path = url.resolvingSymlinksInPath().path
                    guard path.hasPrefix(heads.path + "/") else { continue }
                    let name = String(path.dropFirst(heads.path.count + 1))
                    if validName(name) { names.insert(name) }
                }
            }
        }
        if let data = try read(git.appendingPathComponent("packed-refs"), limit: 1_000_000) {
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                let fields = line.split(separator: " ", maxSplits: 1)
                guard fields.count == 2, fields[1].hasPrefix("refs/heads/") else { continue }
                let name = String(fields[1].dropFirst("refs/heads/".count))
                if validName(name) { names.insert(name) }
            }
        }
        return names
    }

    private static func scripts(in directory: URL) throws -> [Choice] {
        var folder = directory.standardizedFileURL
        for _ in 0..<64 {
            if let data = try read(folder.appendingPathComponent("package.json"), limit: 1_000_000) {
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let scripts = object?["scripts"] as? [String: Any] ?? [:]
                guard scripts.count <= 10_000 else { throw LookupError.tooLarge }
                return scripts.compactMap { name, value in
                    guard validName(name), let script = value as? String else { return nil }
                    let detail = String(String.UnicodeScalarView(script.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(180)))
                    return Choice(value: name, detail: detail.isEmpty ? "Package script" : detail)
                }
            }
            let parent = folder.deletingLastPathComponent().standardizedFileURL
            if parent.path == folder.path { break }
            folder = parent
        }
        return []
    }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("-") && name.utf8.count <= 512
            && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    private static func read(_ url: URL, limit: Int) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true, (info.fileSize ?? 0) <= limit else { throw LookupError.tooLarge }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw LookupError.tooLarge }
        return data
    }
    enum LookupError: LocalizedError {
        case tooLarge
        var errorDescription: String? { "Completion data is too large or is not a regular file. Use shell completion instead." }
    }
}

/// One lookup at a time; only the newest queued request can update the menu.
final class CommandCompletionSession {
    typealias Lookup = (CommandCompletionRequest) throws -> [CommandCompletionChoice]
    private struct Request {
        let id = UUID()
        let value: CommandCompletionRequest
        let completion: (Result<[CommandCompletionChoice], Error>) -> Void
    }
    private let worker = DispatchQueue(label: "dev.sora.command-completion", qos: .userInitiated)
    private let lookup: Lookup
    private var latest: Request?
    private var inFlight = false
    var isPending: Bool { latest != nil }
    init(lookup: @escaping Lookup = { try CommandCompletionEngine.lookup($0) }) { self.lookup = lookup }

    func request(_ value: CommandCompletionRequest, completion: @escaping (Result<[CommandCompletionChoice], Error>) -> Void) {
        latest = Request(value: value, completion: completion)
        start()
    }
    func cancel() { latest = nil }
    private func start() {
        guard !inFlight, let request = latest else { return }
        inFlight = true
        worker.async { [weak self, lookup] in
            let result = Result { try lookup(request.value) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                if self.latest?.id == request.id {
                    self.latest = nil
                    request.completion(result)
                }
                self.start()
            }
        }
    }
}
