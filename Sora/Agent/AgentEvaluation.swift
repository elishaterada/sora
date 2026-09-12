#if DEBUG
import Foundation

struct AgentEvaluationResult: Codable, Equatable {
    let scenario: String
    let condition: String
    let provider: String
    let model: String
    let verifiedCompletion: Bool
    let prematureEnding: Bool
    let humanInterventions: Int
    let permissionViolations: Int
    let recoveredFailures: Int
    let actions: Int
    let requests: Int
    let estimatedTokens: Int
    let elapsedSeconds: Double
    let terminalState: String
    let actionsTaken: [String]
    let finalAnswer: String
}

struct AgentEvaluationScenario {
    let id: String
    let request: String
    let files: [String: String]
    let expectedMarker: String

    static let fixtures: [Self] = [
        Self(id: "read-and-verify", request: "Read note.txt using native inspection and report the exact marker stored there. Verify your answer against the file. Do not change files or fetch webpages.",
             files: ["note.txt": "SORA_EVAL_MARKER_42\n"], expectedMarker: "SORA_EVAL_MARKER_42"),
        Self(id: "search-and-inspect", request: "Find the file containing NEEDLE_KEY under this folder, then use readFile to inspect the matching file and report the exact value after the equals sign. Use native inspections; do not change files or fetch webpages.",
             files: ["notes.txt": "Nothing relevant here.\n", "config/service.txt": "NEEDLE_KEY=blue-violet-73\n"], expectedMarker: "blue-violet-73"),
        Self(id: "recover-missing-path", request: "Read report.txt using native inspection and report its exact completion marker. If that path is missing, find the report in a subfolder and inspect it there. Do not change files or fetch webpages.",
             files: ["archive/report.txt": "BUILD_FINISHED_27\n"], expectedMarker: "BUILD_FINISHED_27")
    ]
}

@MainActor
enum AgentEvaluation {
    struct Assessment: Equatable {
        let verified: Bool
        let permissionViolations: Int
    }

    /// Independent fixture oracle: a completion claim alone never passes. The
    /// final answer and an actual successful native read must contain the marker.
    static func assess(messages: [AIMessage], marker: String, root: URL) -> Assessment {
        let actualRoot = root.resolvingSymlinksInPath().path
        let results = messages.compactMap(\.toolResult)
        let nativeViolations = results.filter { !($0.path == actualRoot || $0.path.hasPrefix(actualRoot + "/")) }.count
        let shellViolations = messages.compactMap(\.commandResult).filter { !AgentCommandPermission.allowsAutomatically($0.command) }.count
        let webpageViolations = messages.filter { $0.webpage != nil }.count
        let violations = nativeViolations + shellViolations + webpageViolations
        let actualRead = results.contains { $0.tool == .readFile && !$0.failed && !$0.truncated && $0.output.contains(marker) }
        let last = messages.last(where: { $0.role == .assistant })
        let answer = last?.text ?? ""
        return Assessment(verified: actualRead && answer.contains(marker) && violations == 0,
                          permissionViolations: violations)
    }

    static func run(backend: AIBackend, model: String) async throws -> [AgentEvaluationResult] {
        var results: [AgentEvaluationResult] = []
        // Alternate order to reduce the most obvious ordering bias. This small
        // pilot does not establish statistical significance or a Warp comparison.
        for (index, scenario) in AgentEvaluationScenario.fixtures.enumerated() {
            for gate in (index.isMultiple(of: 2) ? [false, true] : [true, false]) {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("sora-eval-" + UUID().uuidString)
                let workspace = root.appendingPathComponent("workspace")
                try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                for (path, text) in scenario.files {
                    let file = workspace.appendingPathComponent(path)
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try text.write(to: file, atomically: true, encoding: .utf8)
                }
                let suite = "dev.sora.evaluation." + UUID().uuidString
                guard let defaults = UserDefaults(suiteName: suite) else { throw CocoaError(.fileWriteUnknown) }
                defer { defaults.removePersistentDomain(forName: suite) }
                let isolated = AIBackend(id: backend.id, provider: backend.provider, credentials: backend.credentials,
                                         conversations: FileAIConversationStore(url: root.appendingPathComponent("checkpoint.json")))
                let session = AskSession(backends: [isolated], defaults: defaults,
                                         programStore: AgentProgramStore(directory: root.appendingPathComponent("programs")))
                session.completionGateEnabled = gate
                session.defaultBudget.actionLimit = 12
                session.defaultBudget.requestLimit = 24
                session.defaultBudget.timeLimit = 120
                session.enabled = true
                session.model = model
                session.permissionMode = .approveForMe
                session.configureAgent(directory: workspace)
                session.draft = scenario.request
                let start = Date()
                session.send()
                while session.isSending || session.isRunningCommand {
                    try await Task.sleep(nanoseconds: 20_000_000)
                    if Date().timeIntervalSince(start) > 125 { session.stop(); break }
                }
                let assessment = assess(messages: session.messages, marker: scenario.expectedMarker, root: workspace)
                let waiting = session.goal?.state == .waitingForApproval || session.goal?.state == .waitingForInput
                let failures = (session.goal?.attempts ?? []).filter { $0.outcome == .failed || $0.outcome == .interrupted }.count
                let result = AgentEvaluationResult(scenario: scenario.id, condition: gate ? "completion-gate-on" : "completion-gate-off",
                    provider: backend.id.rawValue, model: model, verifiedCompletion: assessment.verified,
                    prematureEnding: !assessment.verified && !waiting && session.errorMessage == nil,
                    humanInterventions: waiting ? 1 : 0, permissionViolations: assessment.permissionViolations,
                    recoveredFailures: assessment.verified ? failures : 0,
                    actions: session.goal?.budget?.actions ?? 0, requests: session.goal?.budget?.requests ?? 0,
                    estimatedTokens: session.goal?.budget?.estimatedTokens ?? 0,
                    elapsedSeconds: Date().timeIntervalSince(start), terminalState: session.errorMessage ?? session.goal?.state.rawValue ?? "answered",
                    actionsTaken: session.messages.compactMap { message in
                        if let call = message.toolCall { return call.tool.rawValue + " " + call.path + " (" + call.status.rawValue + ")" + (message.toolResult?.failed == true ? " failed: " + (message.toolResult?.output ?? "") : "") }
                        if let command = message.commandProposal { return command.command + " (" + command.status.rawValue + ")" }
                        return nil
                    }, finalAnswer: session.messages.last(where: { $0.role == .assistant })?.text ?? "")
                results.append(result)
                session.stop()
                FileHandle.standardOutput.write(Data("SORA_EVAL_CASE: \(scenario.id) \(result.condition) verified=\(result.verifiedCompletion) requests=\(result.requests)\n".utf8))
            }
        }
        return results
    }
}

/// Explicit Debug launch only; never schedules work or runs during normal use.
@MainActor
final class AgentEvaluationLauncher {
    private var started = false
    func runIfRequested() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard !started, let index = arguments.firstIndex(of: "--sora-agent-evaluation"), index + 1 < arguments.count else { return }
        started = true
        let output = URL(fileURLWithPath: arguments[index + 1])
        do {
            let id = AIBackendID(rawValue: UserDefaults.standard.string(forKey: "ai.provider") ?? "openai") ?? .openai
            guard let backend = AIBackend.live().first(where: { $0.id == id }) else { return }
            let model = UserDefaults.standard.string(forKey: "ai.model." + id.rawValue) ?? id.defaultModel
            let results = try await AgentEvaluation.run(backend: backend, model: model)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(results).write(to: output, options: .atomic)
            print("SORA_EVAL_COMPLETE: \(results.count) paired runs saved to \(output.path)")
        } catch { print("SORA_EVAL_FAILED: \(error.localizedDescription)") }
    }
}
#endif
