import Darwin
import Foundation
import Combine

/// Stable app-support storage with locked, fresh reads and per-layout revisions.
final class ProjectLayoutStore: ObservableObject {
    private struct Catalog: Codable {
        var version = 1
        var layouts: [ProjectLayout] = []
    }
    private struct Version: Decodable { let version: Int }
    static var defaultURL: URL {
        WorkspaceWindowStore.defaultURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Layouts/layouts.json")
    }
    let url: URL
    @Published private(set) var layouts: [ProjectLayout] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var recoveryMessage: String?
    init(url: URL = ProjectLayoutStore.defaultURL) { self.url = url; refresh() }

    func refresh() {
        do { publish(try locked { try read() }); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }
    @discardableResult
    func save(name: String, snapshot: WorkspaceSnapshot) throws -> ProjectLayout {
        let layout = try ProjectLayout(name: name, snapshot: snapshot)
        try update { catalog in
            try Self.checkName(layout.name, excluding: nil, catalog: catalog)
            guard catalog.layouts.count < 50 else { throw ProjectLayout.LayoutError.tooLarge }
            catalog.layouts.append(layout)
        }
        return layout
    }
    func rename(_ layout: ProjectLayout, to name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try update { catalog in
            let index = try Self.currentIndex(layout, catalog: catalog)
            try Self.checkName(name, excluding: layout.id, catalog: catalog)
            catalog.layouts[index].name = name
            catalog.layouts[index].revision = UUID()
            try catalog.layouts[index].validate()
        }
    }
    func delete(_ layout: ProjectLayout) throws {
        try update { catalog in catalog.layouts.remove(at: try Self.currentIndex(layout, catalog: catalog)) }
    }
    func current(_ id: UUID) throws -> ProjectLayout {
        let catalog = try locked { try read() }
        publish(catalog)
        guard let result = catalog.layouts.first(where: { $0.id == id }) else { throw ProjectLayout.LayoutError.changed }
        return result
    }
    private static func currentIndex(_ layout: ProjectLayout, catalog: Catalog) throws -> Int {
        guard let index = catalog.layouts.firstIndex(where: { $0.id == layout.id }),
              catalog.layouts[index].revision == layout.revision else { throw ProjectLayout.LayoutError.changed }
        return index
    }
    private static func checkName(_ name: String, excluding id: UUID?, catalog: Catalog) throws {
        guard !catalog.layouts.contains(where: { $0.id != id && $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame })
        else { throw ProjectLayout.LayoutError.duplicateName }
    }
    private func update(_ change: (inout Catalog) throws -> Void) throws {
        do {
            let updated = try locked {
                var catalog = try read()
                try change(&catalog)
                let encoded = try JSONEncoder().encode(catalog)
                guard encoded.count <= 16_000_000 else { throw ProjectLayout.LayoutError.tooLarge }
                if let previous = try data(at: url) { try write(previous, to: url.appendingPathExtension("backup")) }
                try write(encoded, to: url)
                return catalog
            }
            publish(updated)
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription; throw error }
    }
    private func publish(_ catalog: Catalog) {
        layouts = catalog.layouts.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private func locked<T>(_ operation: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let descriptor = open(url.appendingPathExtension("lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw posixError() }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }
    private func read() throws -> Catalog {
        guard let bytes = try data(at: url) else { return Catalog() }
        do { return try decode(bytes) }
        catch ProjectLayout.LayoutError.unsupportedVersion { throw ProjectLayout.LayoutError.unsupportedVersion }
        catch {
            let originalError = error
            guard let backup = try data(at: url.appendingPathExtension("backup")), let recovered = try? decode(backup) else { throw originalError }
            let preserved = url.appendingPathExtension("unreadable-\(UUID().uuidString)")
            try write(bytes, to: preserved)
            try write(backup, to: url)
            recoveryMessage = "Recovered saved layouts from the previous catalog. The unreadable file was preserved in \(url.deletingLastPathComponent().path)."
            return recovered
        }
    }
    private func decode(_ data: Data) throws -> Catalog {
        guard try JSONDecoder().decode(Version.self, from: data).version == 1 else { throw ProjectLayout.LayoutError.unsupportedVersion }
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        guard catalog.layouts.count <= 50, Set(catalog.layouts.map(\.id)).count == catalog.layouts.count else { throw ProjectLayout.LayoutError.invalidLayout }
        var names = Set<String>()
        for layout in catalog.layouts {
            try layout.validate()
            guard names.insert(layout.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)).inserted else { throw ProjectLayout.LayoutError.duplicateName }
        }
        return catalog
    }
    private func data(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true, (info.fileSize ?? 0) <= 16_000_000 else { throw ProjectLayout.LayoutError.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 16_000_001) ?? Data()
        guard data.count <= 16_000_000 else { throw ProjectLayout.LayoutError.tooLarge }
        return data
    }
    private func write(_ data: Data, to target: URL) throws {
        try data.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        try handle.synchronize()
        let directory = open(target.deletingLastPathComponent().path, O_RDONLY)
        guard directory >= 0 else { throw posixError() }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw posixError() }
    }
    private func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
