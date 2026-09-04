import AppKit
import GhosttyKit

enum GhosttyClipboard {
    static func pasteboard(for location: ghostty_clipboard_e) -> NSPasteboard {
        switch location {
        case GHOSTTY_CLIPBOARD_SELECTION, GHOSTTY_CLIPBOARD_PRIMARY:
            return NSPasteboard(name: .init("dev.sora.selection"))
        default:
            return .general
        }
    }

    static func plainText(from pasteboard: NSPasteboard) -> String? {
        pasteboard.string(forType: .string)
    }

    static func writePlainText(_ text: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func firstPlainText(
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        count: Int
    ) -> String? {
        guard let content, count > 0 else { return nil }
        for index in 0..<count {
            let item = content[index]
            let mime = item.mime.map { String(cString: $0) } ?? ""
            guard mime == "text/plain" || mime.isEmpty else { continue }
            guard item.len > 0, let data = item.data else { continue }
            let bytes = Data(bytes: data, count: item.len)
            if let text = String(data: bytes, encoding: .utf8) {
                return text
            }
        }
        return nil
    }
}
