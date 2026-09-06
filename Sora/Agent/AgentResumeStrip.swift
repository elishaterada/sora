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

    /// Single row only — a second row would cover the grid or reflow the PTY.
    static let primaryRowHeight: CGFloat = 36

    var height: CGFloat { Self.primaryRowHeight }

    /// Prefer live status, then latest follow-up, for the single-row subtitle.
    var statusLine: String? {
        latestFollowUp
    }
}

/// Single-row summary in the reserved slot above the sticky prompt.
struct AgentResumeStripView: View {
    let summary: AgentResumeSummary
    var onResume: () -> Void

    private var isEmpty: Bool {
        summary.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if isEmpty {
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: AgentResumeSummary.primaryRowHeight, maxHeight: AgentResumeSummary.primaryRowHeight)
                    .accessibilityHidden(true)
            } else {
                Button(action: onResume) {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .font(SoraTheme.chromeIconSmall)
                            .foregroundStyle(SoraTheme.accent)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(summary.title)
                                .font(SoraTheme.chromeBodySemibold)
                                .foregroundStyle(SoraTheme.text)
                                .lineLimit(1)
                            if let status = summary.statusLine {
                                Text(status)
                                    .font(SoraTheme.chromeCaption)
                                    .foregroundStyle(SoraTheme.muted)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: SoraTheme.space2)
                        Image(systemName: "chevron.right")
                            .font(SoraTheme.chromeIconSmall)
                            .foregroundStyle(SoraTheme.muted)
                    }
                    .padding(.horizontal, SoraTheme.chromeInset)
                    .frame(maxWidth: .infinity, minHeight: AgentResumeSummary.primaryRowHeight, maxHeight: AgentResumeSummary.primaryRowHeight, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SoraChromeButtonStyle(fill: .clear, cornerRadius: 0))
                .help("Reopen this agent conversation")
                .accessibilityLabel(accessibilityTitle)
            }
        }
        .background {
            if !isEmpty {
                Rectangle().fill(.ultraThinMaterial)
                SoraTheme.fillPanel.opacity(0.45)
            }
        }
        .overlay(alignment: .top) {
            if !isEmpty {
                Rectangle().fill(SoraTheme.hairlineStrong).frame(height: 1)
            }
        }
    }

    private var accessibilityTitle: String {
        if let status = summary.statusLine {
            return "Reopen agent: \(summary.title). \(status)"
        }
        return "Reopen agent: \(summary.title)"
    }
}
