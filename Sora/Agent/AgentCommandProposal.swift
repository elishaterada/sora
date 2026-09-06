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

    struct Match: Equatable {
        let proposal: AgentCommandProposal
        /// Anything the model wrote around the envelope, which stays as the answer.
        let prose: String
    }

    private struct Payload: Decodable {
        let summary: String
        let command: String
    }

    static func match(_ text: String) -> Match? {
        guard let span = AgentEnvelope.span(in: text, opening: openingTag, closing: closingTag),
              let proposal = proposal(fromJSON: span.json)
        else { return nil }
        return Match(proposal: proposal, prose: span.prose)
    }

    static func hasOpeningTag(_ text: String) -> Bool {
        AgentEnvelope.hasOpeningTag(text, opening: openingTag)
    }

    static func proseBeforeEnvelope(in text: String) -> String? {
        AgentEnvelope.proseBeforeEnvelope(in: text, opening: openingTag)
    }

    private static func proposal(fromJSON json: String) -> AgentCommandProposal? {
        let summary: String
        let command: String
        if let payload = try? JSONDecoder().decode(Payload.self, from: Data(json.utf8)) {
            summary = payload.summary
            command = payload.command
        } else if let recovered = AgentEnvelope.recoverStringValues(json: json, keys: ["summary", "command"]),
                  let recoveredSummary = recovered["summary"],
                  let recoveredCommand = recovered["command"] {
            summary = recoveredSummary
            command = recoveredCommand
        } else {
            return nil
        }

        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSummary.isEmpty, trimmedSummary.utf8.count <= 600,
              trimmedSummary.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.properties.generalCategory {
                  case .control, .format, .lineSeparator, .paragraphSeparator:
                      return false
                  default:
                      return true
                  }
              }),
              AgentCommandProposal.isValidCommand(trimmedCommand)
        else { return nil }
        return AgentCommandProposal(summary: trimmedSummary, command: trimmedCommand)
    }
}
