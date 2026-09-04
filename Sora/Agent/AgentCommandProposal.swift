import Foundation

struct AgentCommandProposal: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case pending
        case approved
        case dismissed
    }

    let summary: String
    let command: String
    var status: Status = .pending

    static func isValidCommand(_ command: String) -> Bool {
        !command.isEmpty
            && command.utf8.count <= 4_096
            && command.unicodeScalars.allSatisfy { scalar in
                switch scalar.properties.generalCategory {
                case .control, .format, .lineSeparator, .paragraphSeparator:
                    return false
                default:
                    return true
                }
            }
    }
}

/// Providers return a text envelope so the permission flow remains owned by
/// Sora and does not depend on any provider's tool-call schema.
enum AgentCommandProposalParser {
    static let openingTag = "<SORA_COMMAND>"
    static let closingTag = "</SORA_COMMAND>"

    private struct Payload: Decodable {
        let summary: String
        let command: String
    }

    static func parse(_ text: String) -> AgentCommandProposal? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix(openingTag), value.hasSuffix(closingTag) else { return nil }
        let jsonStart = value.index(value.startIndex, offsetBy: openingTag.count)
        let jsonEnd = value.index(value.endIndex, offsetBy: -closingTag.count)
        guard jsonStart <= jsonEnd else { return nil }
        let json = String(value[jsonStart..<jsonEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(json.utf8)) else { return nil }
        let summary = payload.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = payload.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty, summary.utf8.count <= 600,
              summary.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.properties.generalCategory {
                  case .control, .format, .lineSeparator, .paragraphSeparator:
                      return false
                  default:
                      return true
                  }
              }),
              AgentCommandProposal.isValidCommand(command)
        else { return nil }
        return AgentCommandProposal(summary: summary, command: command)
    }

    static func isStreamingEnvelope(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        return openingTag.hasPrefix(value) || value.hasPrefix(openingTag)
    }
}
