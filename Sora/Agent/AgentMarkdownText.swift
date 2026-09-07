import AppKit
import SwiftUI

/// Renders assistant answers as Markdown using Foundation's parser.
/// Falls back to plain `LinkedText` when parsing fails (e.g. mid-stream noise).
struct AgentMarkdownText: View {
    let text: String
    var relativeTo: URL?
    /// While streaming, tolerate incomplete trailing Markdown without delaying
    /// formatting for blocks that have already arrived.
    var streaming = false

    private var lineSpacing: CGFloat { 3 }

    var body: some View {
        Group {
            if let blocks = AgentMarkdown.blocks(text, streaming: streaming, relativeTo: relativeTo),
               !blocks.isEmpty {
                VStack(alignment: .leading, spacing: SoraTheme.space2) {
                    ForEach(blocks) { block in
                        // A selectable Text swallows link activation on macOS,
                        // so blocks with paths trade selection for clickability.
                        // Fenced code, which is never linked, stays selectable.
                        blockView(block).selectableText(!block.hasLinks)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.openURL, OpenURLAction(handler: openURL))
                .accessibilityLabel(text)
            } else {
                LinkedText(text: text, relativeTo: relativeTo)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: AgentMarkdownBlock) -> some View {
        switch block.kind {
        case .paragraph:
            Text(block.text)
                .lineSpacing(lineSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .heading(let level):
            Text(block.text)
                .lineSpacing(lineSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Headings bind to what follows, so add space above only.
                .padding(.top, level <= 2 ? SoraTheme.space2 : SoraTheme.space1)

        case .listItem(let marker, let depth):
            HStack(alignment: .firstTextBaseline, spacing: SoraTheme.space2) {
                Text(marker)
                    .font(SoraTheme.agentBody)
                    .monospacedDigit()
                    .foregroundStyle(SoraTheme.muted)
                Text(block.text)
                    .lineSpacing(lineSpacing)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(max(0, depth - 1)) * SoraTheme.space4)

        case .codeBlock:
            Text(block.text)
                .lineSpacing(lineSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(SoraTheme.space2)
                .background(
                    RoundedRectangle(cornerRadius: SoraTheme.radiusSmall, style: .continuous)
                        .fill(SoraTheme.fillCode)
                )

        case .blockQuote:
            HStack(alignment: .top, spacing: SoraTheme.space2) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(SoraTheme.hairlineStrong)
                    .frame(width: 2)
                Text(block.text)
                    .lineSpacing(lineSpacing)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func openURL(_ url: URL) -> OpenURLAction.Result {
        if url.isFileURL {
            PathActions.reveal(url)
            return .handled
        }
        NSWorkspace.shared.open(url)
        return .handled
    }
}

private extension View {
    @ViewBuilder
    func selectableText(_ enabled: Bool) -> some View {
        if enabled {
            textSelection(.enabled)
        } else {
            textSelection(.disabled)
        }
    }
}
