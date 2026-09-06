import SwiftUI

/// Chip whose visible label opens a menu of relevant actions.
struct ContextChip: View {
    let title: String
    var systemImage: String?
    var help: String?
    let actions: [ContextChipAction]

    var body: some View {
        if actions.isEmpty {
            label
                .help(help ?? title)
                .accessibilityLabel(title)
        } else {
            Menu {
                ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                    if action.isDivider {
                        Divider()
                    } else {
                        Button(action.title, action: action.handler)
                    }
                }
            } label: {
                label
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help(help ?? title)
            .accessibilityLabel(title)
        }
    }

    private var label: some View {
        HStack(spacing: SoraTheme.space1) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(title)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

struct ContextChipAction {
    var title: String
    var isDivider = false
    var handler: () -> Void

    static func divider() -> ContextChipAction {
        ContextChipAction(title: "", isDivider: true, handler: {})
    }
}

enum ContextChipActions {
    static func path(_ url: URL) -> [ContextChipAction] {
        [
            ContextChipAction(title: "Reveal in Finder") { PathActions.reveal(url) },
            ContextChipAction(title: "Copy Path") { PathActions.copyPath(url) },
            ContextChipAction(title: "Copy Display Path") { PathActions.copyDisplayPath(url) }
        ]
    }

    static func branch(_ name: String, repositoryRoot: URL?) -> [ContextChipAction] {
        var items = [
            ContextChipAction(title: "Copy Branch Name") { PathActions.copy(name) }
        ]
        if let repositoryRoot {
            items.append(.divider())
            items.append(ContextChipAction(title: "Reveal Repository") {
                PathActions.reveal(repositoryRoot)
            })
        }
        return items
    }

    static func command(_ command: String) -> [ContextChipAction] {
        [
            ContextChipAction(title: "Copy Command") { PathActions.copy(command) }
        ]
    }
}

/// Renders prose with filesystem paths as focusable, activatable links.
struct LinkedText: View {
    let text: String
    var relativeTo: URL?
    var font: Font = SoraTheme.agentBody
    var monospaced = false

    private var segments: [TextSegment] {
        PathLinkParser.segments(in: text, relativeTo: relativeTo)
    }

    var body: some View {
        LinkedTextFlow(segments: segments, font: resolvedFont)
            .textSelection(.enabled)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(text)
    }

    private var resolvedFont: Font {
        monospaced ? SoraTheme.agentMono : font
    }
}

/// Wraps mixed text runs and path buttons onto successive lines.
private struct LinkedTextFlow: View {
    let segments: [TextSegment]
    var font: Font

    var body: some View {
        FlowLayout(spacing: 0, lineSpacing: 4) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let value):
                    Text(value)
                        .font(font)
                        .foregroundStyle(SoraTheme.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(nil)
                case .path(let label, let url):
                    Button {
                        PathActions.reveal(url)
                    } label: {
                        Text(label)
                            .font(font)
                            .underline()
                            .foregroundStyle(SoraTheme.accent)
                    }
                    .buttonStyle(.plain)
                    .help(url.path)
                    .accessibilityLabel("Reveal \(label)")
                    .accessibilityAddTraits(.isLink)
                    .contextMenu {
                        Button("Reveal in Finder") { PathActions.reveal(url) }
                        Button("Copy Path") { PathActions.copyPath(url) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Simple left-to-right wrapping layout for mixed text/control runs.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 0
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var width: CGFloat = 0
        for subview in subviews {
            let unconstrained = subview.sizeThatFits(.unspecified)
            let remaining = maxWidth - x
            let fits = unconstrained.width <= remaining || x == 0
            let proposedWidth: CGFloat
            if fits {
                proposedWidth = min(unconstrained.width, maxWidth)
            } else {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
                proposedWidth = min(unconstrained.width, maxWidth)
            }
            let size = subview.sizeThatFits(ProposedViewSize(width: proposedWidth, height: nil))
            if x > 0, size.width > remaining {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            width = max(width, min(maxWidth, x))
            if size.width >= maxWidth - 0.5 {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        let maxWidth = bounds.width
        for subview in subviews {
            let remaining = bounds.maxX - x
            let unconstrained = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, unconstrained.width > remaining {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            let proposedWidth = min(unconstrained.width, maxWidth)
            let size = subview.sizeThatFits(ProposedViewSize(width: proposedWidth, height: nil))
            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            if size.width >= maxWidth - 0.5 {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
        }
    }
}
