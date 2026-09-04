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
