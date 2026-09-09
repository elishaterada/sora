import Foundation

/// Disk-safe tab list. Folders and stable identities; PTYs are recreated.
struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    /// Empty string means the default shell working directory.
    var directories: [String]
    var selectedIndex: Int
    var sessionIDs: [UUID]?
    var tabNames: [String]?
    var splitIDs: [UUID]?
    var windowFrame: String?
    var splitFraction: Double?

    static let empty = WorkspaceSnapshot(directories: [""], selectedIndex: 0)

    init(directories: [String], selectedIndex: Int, sessionIDs: [UUID]? = nil, tabNames: [String]? = nil) {
        let dirs = directories.isEmpty ? [""] : directories
        self.tabNames = tabNames
        self.sessionIDs = sessionIDs
        self.directories = dirs
        self.selectedIndex = min(max(0, selectedIndex), dirs.count - 1)
    }
}

/// Plain-text scrollback only: never interpreted as shell input.
enum TerminalHistoryArchive {
    static func url(for id: UUID) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sora/TerminalHistory", isDirectory: true)
            .appendingPathComponent(id.uuidString + ".txt")
    }

    /// Preserve SGR appearance only. Discard OSC, cursor movement, and other
    /// terminal commands so restoring a transcript cannot invoke side effects.
    static func sanitized(_ text: String) -> String {
        let chars = Array(text.unicodeScalars)
        var result: [Unicode.Scalar] = []
        result.reserveCapacity(chars.count)
        var index = 0
        while index < chars.count {
            let scalar = chars[index]
            if scalar.value == 27 {
                index += 1
                guard index < chars.count else { break }
                if chars[index] == "[" {
                    let start = index - 1
                    index += 1
                    let parameters = index
                    while index < chars.count, (0x30...0x3f).contains(chars[index].value) { index += 1 }
                    let valid = chars[parameters..<index].allSatisfy { (48...57).contains($0.value) || $0 == ";" || $0 == ":" }
                    if index < chars.count, chars[index] == "m", valid {
                        result.append(contentsOf: chars[start...index])
                        index += 1
                    } else {
                        while index < chars.count, !(0x40...0x7e).contains(chars[index].value) { index += 1 }
                        if index < chars.count { index += 1 }
                    }
                } else if chars[index] == "]" || chars[index] == "P" || chars[index] == "_" || chars[index] == "^" {
                    index += 1
                    while index < chars.count {
                        if chars[index].value == 7 { index += 1; break }
                        if chars[index].value == 27, index + 1 < chars.count, chars[index + 1] == "\\" { index += 2; break }
                        index += 1
                    }
                } else {
                    index += 1
                }
                continue
            }
            if scalar == "\n" || scalar == "\t" || ![.control, .format].contains(scalar.properties.generalCategory) {
                result.append(scalar)
            }
            index += 1
        }
        return String(String.UnicodeScalarView(result)) + "\u{1b}[0m"
    }

    /// The launch banner is UI chrome, not command output. Replaying it would
    /// archive another copy on every quit, including sessions with no commands.
    static func removingRestoreBanners(_ text: String) -> String {
        let marker = "── Previous session ended · New shell ──"
        guard text.contains(marker) else { return text }
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            let plain = line.replacingOccurrences(of: "\u{1b}\\[[0-9;:]*m", with: "", options: .regularExpression)
            if plain.trimmingCharacters(in: .whitespacesAndNewlines) == marker {
                // Retain SGR changes on the banner so subsequent output keeps
                // its appearance, but remove the launch-only spacer and text.
                if lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
                let controls = line.replacingOccurrences(of: marker, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !controls.isEmpty { lines.append(controls) }
            } else {
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    static func save(_ text: String, for id: UUID) throws {
        let url = url(for: id)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let safe = removingRestoreBanners(sanitized(text))
        let data = Data(safe.utf8.suffix(2_000_000))
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Serial, coalesced disk work. Only immutable snapshots cross from the UI;
/// libghostty export remains on its owning thread. Flush only at termination.
final class TerminalHistoryWriter: @unchecked Sendable {
    struct Snapshot: Sendable {
        let id: UUID
        let text: String?
        let draft: String
    }

    private let queue = DispatchQueue(label: "dev.sora.history-writer", qos: .utility)
    private let lock = NSLock()
    private var pending: [UUID: Snapshot] = [:]
    private var scheduled = false
    private let write: @Sendable (Snapshot) -> Void

    init(write: @escaping @Sendable (Snapshot) -> Void = { snapshot in
        do {
            let url = TerminalHistoryArchive.url(for: snapshot.id).appendingPathExtension("draft")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            try Data(snapshot.draft.utf8.prefix(100_000)).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { NSLog("Could not save terminal draft: %@", error.localizedDescription) }
        if let text = snapshot.text, !text.isEmpty {
            do { try TerminalHistoryArchive.save(text, for: snapshot.id) }
            catch { NSLog("Could not save terminal history: %@", error.localizedDescription) }
        }
    }) {
        self.write = write
    }

    func enqueue(_ snapshot: Snapshot) {
        lock.lock()
        pending[snapshot.id] = snapshot
        if !scheduled {
            scheduled = true
            queue.async { self.drain() }
        }
        lock.unlock()
    }

    func flush() { queue.sync {} }

    private func drain() {
        while true {
            lock.lock()
            guard let id = pending.keys.first, let snapshot = pending.removeValue(forKey: id) else {
                scheduled = false
                lock.unlock()
                return
            }
            lock.unlock()
            write(snapshot)
        }
    }
}
