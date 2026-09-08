import AppKit
import SwiftUI

/// Renders assistant answers as Markdown using Foundation's parser.
/// Falls back to plain `LinkedText` when parsing fails (e.g. mid-stream noise).
struct AgentMarkdownText: View, Equatable {
    let text: String
    var relativeTo: URL?
    /// Render plain text during streaming; format once the response completes.
    var streaming = false

    var body: some View {
        Group {
            if streaming {
                // Avoid reparsing the growing answer and rebuilding hundreds of
                // Markdown views on every token. Apply rich formatting on completion.
                Text(text).font(SoraTheme.agentBody)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else if let blocks = AgentMarkdown.blocks(text, streaming: false, relativeTo: relativeTo),
               !blocks.isEmpty {
                Text(combined(blocks))
                .selectableText(!blocks.contains(where: { $0.hasLinks }))
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.openURL, OpenURLAction(handler: openURL))
                .accessibilityLabel(text)
            } else {
                LinkedText(text: text, relativeTo: relativeTo)
            }
        }
    }

    private func combined(_ blocks: [AgentMarkdownBlock]) -> AttributedString {
        var result = AttributedString()
        for (index, block) in blocks.enumerated() {
            if index > 0 { result.append(AttributedString("\n\n")) }
            if case .listItem(let marker, let depth) = block.kind {
                result.append(AttributedString(String(repeating: "  ", count: max(0, depth - 1)) + marker + " "))
            }
            result.append(block.text)
        }
        return result
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
