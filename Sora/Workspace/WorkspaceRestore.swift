import Foundation

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

/// App-owned window catalog. Updating one window never replaces another's tabs.
final class WorkspaceWindowStore {
    static let defaultsKey = "dev.sora.workspace.windows.v1"
    static let terminationApproved = Notification.Name("sora.terminationApproved")
    private let defaults: UserDefaults
    private(set) var windows: [WorkspaceWindowRecord]
    var isTerminating = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey) {
            do {
                let decoded = try JSONDecoder().decode([WorkspaceWindowRecord].self, from: data)
                var seen = Set<UUID>()
                windows = decoded.filter { seen.insert($0.id).inserted }
            } catch {
                if defaults.data(forKey: Self.defaultsKey + ".unreadable") == nil {
                    defaults.set(data, forKey: Self.defaultsKey + ".unreadable")
                }
                NSLog("Could not read window catalog; preserving it and loading legacy workspace: %@", error.localizedDescription)
                windows = [WorkspaceWindowRecord(id: UUID(), snapshot: WorkspaceRestore.load(from: defaults))]
            }
        } else {
            windows = [WorkspaceWindowRecord(id: UUID(), snapshot: WorkspaceRestore.load(from: defaults))]
        }
        if windows.isEmpty { windows = [WorkspaceWindowRecord(id: UUID(), snapshot: .empty)] }
    }

    func snapshot(for id: UUID) -> WorkspaceSnapshot {
        windows.first { $0.id == id }?.snapshot ?? .empty
    }

    func save(_ snapshot: WorkspaceSnapshot, for id: UUID) {
        if let index = windows.firstIndex(where: { $0.id == id }) {
            windows[index].snapshot = snapshot
        } else {
            windows.append(WorkspaceWindowRecord(id: id, snapshot: snapshot))
        }
        write()
    }

    func close(_ id: UUID) {
        guard !isTerminating else { return }
        windows.removeAll { $0.id == id }
        write()
    }

    private func write() {
        do { defaults.set(try JSONEncoder().encode(windows), forKey: Self.defaultsKey) }
        catch { NSLog("Could not save terminal windows: %@", error.localizedDescription) }
    }
}
