import SwiftUI

/// Warp-style chip: the visible label opens a menu of relevant actions.
struct ContextChip: View {
    let title: String
    var systemImage: String?
    var help: String?
    let actions: [ContextChipAction]

    var body: some View {
        Menu {
            ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                if action.isDivider {
                    Divider()
                } else {
                    Button(action.title, action: action.handler)
                }
            }
        } label: {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(help ?? title)
        .accessibilityLabel(title)
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

/// Renders prose with filesystem paths as tappable chips.
struct LinkedText: View {
    let text: String
    var relativeTo: URL?
    var font: Font = .body
    var monospaced = false

    var body: some View {
        let segments = PathLinkParser.segments(in: text, relativeTo: relativeTo)
        // Keep selection for plain runs; path chips stay menu buttons.
        Text(attributed(segments))
            .font(resolvedFont)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                if url.isFileURL {
                    PathActions.reveal(url)
                    return .handled
                }
                return .systemAction
            })
    }

    private var resolvedFont: Font {
        monospaced ? .system(.body, design: .monospaced) : font
    }

    private func attributed(_ segments: [TextSegment]) -> AttributedString {
        var result = AttributedString()
        for segment in segments {
            switch segment {
            case .text(let value):
                result += AttributedString(value)
            case .path(let label, let url):
                var link = AttributedString(label)
                link.link = url
                link.foregroundColor = .accentColor
                link.underlineStyle = .single
                result += link
            }
        }
        return result
    }
}
