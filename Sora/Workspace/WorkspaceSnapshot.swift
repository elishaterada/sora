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
    var paneLayout: PaneLayout<UUID>?
    var isPaneMaximized: Bool?

    static let empty = WorkspaceSnapshot(directories: [""], selectedIndex: 0)

    init(directories: [String], selectedIndex: Int, sessionIDs: [UUID]? = nil, tabNames: [String]? = nil) {
        let dirs = directories.isEmpty ? [""] : directories
        self.tabNames = tabNames
        self.sessionIDs = sessionIDs
        self.directories = dirs
        self.selectedIndex = min(max(0, selectedIndex), dirs.count - 1)
    }
    private enum CodingKeys: String, CodingKey {
        case directories, selectedIndex, sessionIDs, tabNames, splitIDs, windowFrame, splitFraction, paneLayout, isPaneMaximized
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(directories: try values.decode([String].self, forKey: .directories),
                  selectedIndex: try values.decode(Int.self, forKey: .selectedIndex),
                  sessionIDs: try values.decodeIfPresent([UUID].self, forKey: .sessionIDs),
                  tabNames: try values.decodeIfPresent([String].self, forKey: .tabNames))
        splitIDs = try values.decodeIfPresent([UUID].self, forKey: .splitIDs)
        windowFrame = try values.decodeIfPresent(String.self, forKey: .windowFrame)
        splitFraction = try values.decodeIfPresent(Double.self, forKey: .splitFraction)
        paneLayout = try values.decodeIfPresent(PaneLayout<UUID>.self, forKey: .paneLayout)
        isPaneMaximized = try values.decodeIfPresent(Bool.self, forKey: .isPaneMaximized)
        if let paneLayout, !paneLayout.isValid(allowed: Set(sessionIDs ?? [])) {
            throw DecodingError.dataCorruptedError(forKey: .paneLayout, in: values, debugDescription: "Invalid terminal pane arrangement")
        }
    }

}

/// Styled scrollback and passive block metadata, never interpreted as shell input.
enum TerminalHistoryArchive {
    private static let boundaryPayloads = ["133;A;aid=sora-archive", "133;P;k=s;aid=sora-archive",
                                           "133;B;aid=sora-archive", "133;C;aid=sora-archive"]

    static func url(for id: UUID) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sora/TerminalHistory", isDirectory: true)
            .appendingPathComponent(id.uuidString + ".txt")
    }

    /// Preserve SGR and the exact replay-only boundary markers from Ghostty.
    /// Discard other OSC, cursor movement, and terminal commands.
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
                    let isOSC = chars[index] == "]"
                    index += 1
                    let start = index
                    while index < chars.count {
                        let terminatorLength = chars[index].value == 7 ? 1
                            : (chars[index].value == 27 && index + 1 < chars.count && chars[index + 1] == "\\" ? 2 : 0)
                        if terminatorLength > 0 {
                            if isOSC, index - start <= 32 {
                                let payload = String(String.UnicodeScalarView(chars[start..<index]))
                                if boundaryPayloads.contains(payload) {
                                    result.append(contentsOf: "\u{1b}]\(payload)\u{1b}\\".unicodeScalars)
                                }
                            }
                            index += terminatorLength
                            break
                        }
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
            let styled = line.replacingOccurrences(of: "\u{1b}\\[[0-9;:]*m", with: "", options: .regularExpression)
            let plain = boundaryPayloads.reduce(styled) {
                $0.replacingOccurrences(of: "\u{1b}]\($1)\u{1b}\\", with: "")
            }
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

    /// The native exporter appends one synthetic output marker after the screen
    /// to separate the next shell's launch chrome. It is not command evidence.
    static func preparingGhosttyExport(_ text: String, promptReady: Bool) -> String {
        let terminator = "\u{1b}]133;C;aid=sora-archive\u{1b}\\"
        guard promptReady, text.hasSuffix(terminator) else { return text }
        return removingUnsubmittedPrompts(String(text.dropLast(terminator.count))) + terminator
    }

    /// The current edit buffer is saved separately. Replaying its unfinished
    /// prompt adds another fake command on each launch and consumes history space.
    /// Only canonical archive prompt/input pairs without a command-start marker
    /// are removed; completed/running output and unstructured legacy text remain.
    static func removingUnsubmittedPrompts(_ text: String) -> String {
        let prompt = "\u{1b}]133;A;aid=sora-archive\u{1b}\\"
        let input = "\u{1b}]133;B;aid=sora-archive\u{1b}\\"
        let output = "\u{1b}]133;C;aid=sora-archive\u{1b}\\"
        var end = text.endIndex
        while let range = text.range(of: prompt, options: .backwards, range: text.startIndex..<end) {
            let tail = text[range.upperBound..<end]
            guard tail.contains(input), !tail.contains(output) else { break }
            end = range.lowerBound
        }
        return String(text[..<end])
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
