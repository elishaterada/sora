import AppKit
import SwiftUI

/// Renders assistant answers as Markdown using Foundation's parser.
/// Uses plain text while streaming or when parsing fails.
struct AgentMarkdownText: View, Equatable {
    let text: String
    var relativeTo: URL?
    /// Render plain text during streaming; format once the response completes.
    var streaming = false

    var body: some View {
        AgentSelectableText(content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var content: NSAttributedString {
        if !streaming,
           let blocks = AgentMarkdown.blocks(text, relativeTo: relativeTo), !blocks.isEmpty {
            return NSAttributedString(combined(blocks))
        }
        // Keep streaming inexpensive; parse rich formatting only on completion.
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: SoraTheme.terminalFontSize),
            .foregroundColor: NSColor(SoraTheme.text)
        ])
    }

    private func combined(_ blocks: [AgentMarkdownBlock]) -> AttributedString {
        var result = AttributedString()
        for (index, block) in blocks.enumerated() {
            if index > 0 { result.append(AttributedString("\n\n")) }
            if case .listItem(let marker, let depth) = block.kind {
                result.append(AttributedString(String(repeating: "  ", count: max(0, depth - 1)) + marker + " "))
            }
            var styled = block.text
            // NSTextView consumes concrete font traits, unlike SwiftUI Text,
            // which also interprets Markdown's inline presentation intents.
            for run in styled.runs {
                guard let intent = run.inlinePresentationIntent,
                      let font = run.appKit.font else { continue }
                var traits: NSFontTraitMask = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
                if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
                if !traits.isEmpty {
                    styled[run.range].appKit.font = NSFontManager.shared.convert(font, toHaveTrait: traits)
                }
                if intent.contains(.strikethrough) {
                    styled[run.range].appKit.strikethroughStyle = .single
                }
            }
            result.append(styled)
        }
        return result
    }

}

/// A single native text surface allows selection across paragraphs and links.
struct AgentSelectableText: NSViewRepresentable {
    let content: NSAttributedString

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView(frame: .zero)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.delegate = context.coordinator
        view.linkTextAttributes = [.foregroundColor: SoraTheme.nsAccent,
                                   .underlineStyle: NSUnderlineStyle.single.rawValue]
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        // Unrelated transcript updates must not reset an active selection.
        guard view.textStorage?.isEqual(to: content) != true else { return }
        let selection = view.selectedRange()
        view.textStorage?.setAttributedString(content)
        let location = min(selection.location, content.length)
        view.setSelectedRange(NSRange(location: location,
                                      length: min(selection.length, content.length - location)))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0,
              let container = nsView.textContainer, let layout = nsView.layoutManager else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSTextViewDelegate {
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return false }
            if url.isFileURL {
                PathActions.reveal(url)
            } else {
                NSWorkspace.shared.open(url)
            }
            return true
        }
    }
}
