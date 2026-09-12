import Foundation
import Combine
import Darwin

enum WorkspaceRestore {
    static let defaultsKey = "dev.sora.workspace.snapshot"

    static func load(from defaults: UserDefaults = .standard) -> WorkspaceSnapshot {
        guard let data = defaults.data(forKey: defaultsKey) else {
            return .empty
        }
        return (try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data)) ?? .empty
    }

    static func save(_ snapshot: WorkspaceSnapshot, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}


struct WorkspaceWindowRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var snapshot: WorkspaceSnapshot
}

/// Synchronous, atomic workspace checkpoints outside the replaceable app bundle.
/// A locked read/modify/write plus per-window revisions rejects stale app copies.
final class WorkspaceWindowStore: ObservableObject {
    static let defaultsKey = "dev.sora.workspace.windows.v1"
    static let terminationApproved = Notification.Name("sora.terminationApproved")
    static let checkpointRequested = Notification.Name("sora.checkpointRequested")

    private struct Entry: Codable {
        var window: WorkspaceWindowRecord
        var revision: UUID
    }
    private struct Catalog: Codable {
        var version = 1
        var entries: [Entry]
    }
    private enum StoreError: LocalizedError {
        case unsupportedVersion, staleWindow, invalidCatalog
        var errorDescription: String? {
            switch self {
            case .unsupportedVersion: return "This workspace was saved by a newer Sora version. Open that version to keep saving your sessions."
            case .staleWindow: return "Another Sora copy changed this workspace. Quit this copy and use the other copy to avoid overwriting your sessions."
            case .invalidCatalog: return "The saved workspace could not be read. The original files have been kept for recovery."
            }
        }
    }

    static var defaultURL: URL {
        var root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sora", isDirectory: true)
        // Verification builds must never replace the installed app's workspace.
        if let identifier = Bundle.main.bundleIdentifier, identifier != "dev.sora.app" {
            root.appendPathComponent("Development/\(identifier)", isDirectory: true)
        }
        return root.appendingPathComponent("Workspace/windows.json")
    }

    let url: URL
    private let defaults: UserDefaults
    private var revisions: [UUID: UUID] = [:]
    private var writable = true
    private(set) var windows: [WorkspaceWindowRecord] = []
    @Published private(set) var persistenceError: String?
    var isTerminating = false

    init(defaults: UserDefaults = .standard, url: URL = WorkspaceWindowStore.defaultURL) {
        self.defaults = defaults
        self.url = url
        do {
            let catalog = try withLock { try readOrMigrate() }
            windows = catalog.entries.map(\.window)
            revisions = Dictionary(uniqueKeysWithValues: catalog.entries.map { ($0.window.id, $0.revision) })
        } catch {
            writable = false
            report(error)
        }
        if windows.isEmpty { windows = [WorkspaceWindowRecord(id: UUID(), snapshot: .empty)] }
    }

    func snapshot(for id: UUID) -> WorkspaceSnapshot {
        windows.first { $0.id == id }?.snapshot ?? .empty
    }

    /// False means callers must also preserve existing scrollback and drafts.
    @discardableResult
    func save(_ snapshot: WorkspaceSnapshot, for id: UUID) -> Bool {
        mutate(id) { catalog in
            if let index = catalog.entries.firstIndex(where: { $0.window.id == id }) {
                if catalog.entries[index].window.snapshot == snapshot { return }
                catalog.entries[index] = Entry(window: .init(id: id, snapshot: snapshot), revision: UUID())
            } else {
                catalog.entries.append(Entry(window: .init(id: id, snapshot: snapshot), revision: UUID()))
            }
        }
    }

    func close(_ id: UUID, explicitlyRequested: Bool) {
        guard explicitlyRequested, !isTerminating else { return }
        _ = mutate(id) { $0.entries.removeAll { $0.window.id == id } }
    }

    private func mutate(_ id: UUID, change: (inout Catalog) -> Void) -> Bool {
        guard writable else { return false }
        do {
            try withLock {
                var catalog = try readOrMigrate()
                guard catalog.entries.first(where: { $0.window.id == id })?.revision == revisions[id] else {
                    throw StoreError.staleWindow
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let before = try encoder.encode(catalog)
                change(&catalog)
                let data = try encoder.encode(catalog)
                if before != data {
                    // A valid previous generation is retained even across app replacement.
                    try durableWrite(before, to: url.appendingPathExtension("backup"))
                    try durableWrite(data, to: url)
                }
                windows = catalog.entries.map(\.window)
                revisions[id] = catalog.entries.first(where: { $0.window.id == id })?.revision
            }
            persistenceError = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    private func readOrMigrate() throws -> Catalog {
        if FileManager.default.fileExists(atPath: url.path) {
            do { return try decode(Data(contentsOf: url)) }
            catch StoreError.unsupportedVersion { throw StoreError.unsupportedVersion }
            catch {
                let originalError = error
                // Preserve unreadable bytes; never rotate them over a good backup.
                let backup = url.appendingPathExtension("backup")
                guard let data = try? Data(contentsOf: backup), let catalog = try? decode(data) else {
                    throw originalError
                }
                let preserved = url.appendingPathExtension("unreadable-\(UUID().uuidString)")
                try FileManager.default.copyItem(at: url, to: preserved)
                try durableWrite(data, to: url)
                NSLog("Recovered terminal workspace from its previous checkpoint; original kept at %@", preserved.path)
                return catalog
            }
        }
        // A missing primary with a valid backup is recovery, not a new install.
        let backup = url.appendingPathExtension("backup")
        if FileManager.default.fileExists(atPath: backup.path) {
            let data = try Data(contentsOf: backup)
            let catalog = try decode(data)
            try durableWrite(data, to: url)
            return catalog
        }
        let records: [WorkspaceWindowRecord]
        if let data = defaults.data(forKey: Self.defaultsKey) {
            records = try JSONDecoder().decode([WorkspaceWindowRecord].self, from: data)
        } else if let data = defaults.data(forKey: WorkspaceRestore.defaultsKey) {
            records = [.init(id: UUID(), snapshot: try JSONDecoder().decode(WorkspaceSnapshot.self, from: data))]
        } else { records = [] }
        var seen = Set<UUID>()
        let catalog = Catalog(entries: records.filter { seen.insert($0.id).inserted }
            .map { Entry(window: $0, revision: UUID()) })
        let data = try JSONEncoder().encode(catalog)
        try durableWrite(data, to: url.appendingPathExtension("backup"))
        try durableWrite(data, to: url)
        // Keep both old preference keys untouched for recovery/downgrade inspection.
        return catalog
    }

    private func decode(_ data: Data) throws -> Catalog {
        struct Header: Decodable { let version: Int }
        guard try JSONDecoder().decode(Header.self, from: data).version == 1 else { throw StoreError.unsupportedVersion }
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        guard Set(catalog.entries.map { $0.window.id }).count == catalog.entries.count else { throw StoreError.invalidCatalog }
        return catalog
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let descriptor = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func durableWrite(_ data: Data, to destination: URL) throws {
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        let file = try FileHandle(forWritingTo: destination)
        defer { try? file.close() }
        try file.synchronize()
        // Commit the atomic replacement's directory entry as well as file bytes.
        let directory = open(destination.deletingLastPathComponent().path, O_RDONLY)
        guard directory >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(directory) }
        guard fsync(directory) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func report(_ error: Error) {
        let message = error.localizedDescription
        if persistenceError != message { NSLog("Could not persist terminal workspace: %@", message) }
        persistenceError = message
    }
}
