import Combine
import Foundation

/// A window owns one runtime per tab. Selecting a different pane only changes
/// presentation; it cannot cancel another tab's provider request or process.
@MainActor
final class AgentWorkspace: ObservableObject {
    private var sessions: [UUID: AskSession] = [:]
    private let makeSession: (UUID) -> AskSession

    init(windowID: UUID, skins: SkinLibrary? = nil) {
        makeSession = { tabID in
            let session = AskSession(backends: AIBackend.live(windowID: windowID, tabID: tabID), restoreConversation: true)
            session.skinLibrary = skins
            return session
        }
    }

    init(makeSession: @escaping (UUID) -> AskSession) { self.makeSession = makeSession }

    func session(for tabID: UUID) -> AskSession {
        if let session = sessions[tabID] { return session }
        let session = makeSession(tabID)
        session.bindTab(tabID)
        sessions[tabID] = session
        return session
    }

    func isBusy(in ids: [UUID]) -> Bool {
        ids.contains { sessions[$0].map { $0.isSending || $0.isRunningCommand } == true }
    }

    func discard(_ tabID: UUID) {
        sessions.removeValue(forKey: tabID)?.stop()
    }

    func stopAll() { sessions.values.forEach { $0.stop() } }
}
