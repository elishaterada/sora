import SwiftUI

struct AgentResumeSummary: Equatable, Sendable {
    var title: String
    var latestFollowUp: String?

    static func title(from question: String) -> String {
        var text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        for prefix in ["help me ", "can you ", "could you ", "would you ", "please "] {
            if lower.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count))
                break
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = text.first else { return "Agent conversation" }
        text = String(first).uppercased() + text.dropFirst()
        if text.count <= 56 { return text }
        return String(text.prefix(53)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    static let primaryRowHeight: CGFloat = 40
    static let followUpRowHeight: CGFloat = 32

    var height: CGFloat {
        latestFollowUp == nil ? Self.primaryRowHeight : Self.primaryRowHeight + Self.followUpRowHeight
    }
}

/// Warp-style summary above the sticky prompt: click to re-enter the tab's agent thread.
struct AgentResumeStripView: View {
    let summary: AgentResumeSummary
    var onResume: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onResume) {
                HStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.text.bubble.right.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(summary.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.right.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: AgentResumeSummary.primaryRowHeight, maxHeight: AgentResumeSummary.primaryRowHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Reopen this agent conversation")

            if let followUp = summary.latestFollowUp {
                Divider().opacity(0.35)
                Button(action: onResume) {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.accentColor.opacity(0.85))
                        Text(followUp)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Image(systemName: "return")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.leading, 12)
                    .frame(maxWidth: .infinity, minHeight: AgentResumeSummary.followUpRowHeight, maxHeight: AgentResumeSummary.followUpRowHeight, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Continue this follow-up in agent mode")
            }
        }
        .background(Color.black.opacity(0.55))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1)
        }
    }
}
