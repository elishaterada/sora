import AppKit

enum GhosttyClipboard {
    static let selectionPasteboard = NSPasteboard(name: .init("dev.sora.selection"))

    static func plainText(from pasteboard: NSPasteboard) -> String? {
        pasteboard.string(forType: .string)
    }

    static func writePlainText(_ text: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
