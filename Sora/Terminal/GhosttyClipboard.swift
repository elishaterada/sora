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
    static func hasImage(in pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: [.png, .tiff]) != nil || TerminalImageDrop.canRead(pasteboard)
    }

    /// Publish pixels, not a file URL or a string. Local interactive CLIs such
    /// as Codex read these representations directly through the OS clipboard.
    static func writeImage(at url: URL, to pasteboard: NSPasteboard) throws {
        let data = try Data(contentsOf: url)
        guard let image = NSBitmapImageRep(data: data),
              let png = image.representation(using: .png, properties: [:]),
              let tiff = image.tiffRepresentation else { throw TerminalImageDrop.DropError.unsupportedImage }
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setData(tiff, forType: .tiff)
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            throw NSError(domain: "Sora.Clipboard", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The image could not be copied to the clipboard."])
        }
    }

}
