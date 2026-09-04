import Foundation

struct CommandRun: Identifiable, Equatable, Sendable {
    let id: UUID
    let command: String
    let cwd: URL
    let startedAt: Date
    let finishedAt: Date
    let exitCode: Int
    let durationNanos: UInt64
}
