import AppKit
import CoreText

enum GhosttyInput {
    /// Matches `GHOSTTY_MODS_*` in ghostty.h. `command` is `GHOSTTY_MODS_SUPER`.
    enum Mods {
        static let none: UInt32 = 0
        static let shift: UInt32 = 1 << 0
        static let ctrl: UInt32 = 1 << 1
        static let alt: UInt32 = 1 << 2
        static let command: UInt32 = 1 << 3
        static let caps: UInt32 = 1 << 4
    }

    static func modBits(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = Mods.none
        if flags.contains(.shift) { mods |= Mods.shift }
        if flags.contains(.control) { mods |= Mods.ctrl }
        if flags.contains(.option) { mods |= Mods.alt }
        if flags.contains(.command) { mods |= Mods.command }
        if flags.contains(.capsLock) { mods |= Mods.caps }
        return mods
    }

    static func scrollPrecisionBit(_ precision: Bool) -> UInt32 {
        precision ? 1 : 0
    }

    /// Text Ghostty should encode for this key. Control characters and function-key
    /// private-use values are omitted so Ghostty can encode them from the keycode.
    static func text(from event: NSEvent) -> String? {
        guard let characters = event.characters, !characters.isEmpty else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }
            if (0xF700...0xF8FF).contains(scalar.value) {
                return nil
            }
        }
        return characters
    }

    /// libghostty mouse coordinates are top-left origin. AppKit view points
    /// (unflipped) are bottom-left origin.
    static func surfaceMousePoint(viewPoint: NSPoint, viewHeight: CGFloat) -> NSPoint {
        NSPoint(x: viewPoint.x, y: viewHeight - viewPoint.y)
    }

    /// Cell width in the same point space as `ghostty_surface_ime_point`.
    /// Prefer Ghostty's CELL_SIZE when its height already matches the IME
    /// height. Rescale only when the units differ, and fall back to the font
    /// advance if rescale looks like a points/pixels mix-up (~2×) — that
    /// shift hides a leading space under the last typed character.
    static func ghostTextCellWidth(
        imeHeight: CGFloat,
        cellSize: NSSize,
        font: CTFont
    ) -> CGFloat {
        let advance = monospaceAdvance(font: font)
        let roundedAdvance = advance > 0 ? advance.rounded() : 0

        if imeHeight > 0, cellSize.width > 0, cellSize.height > 0 {
            let heightDelta = abs(cellSize.height - imeHeight)
            if heightDelta <= max(1, imeHeight * 0.15) {
                return cellSize.width
            }
            let rescaled = cellSize.width * (imeHeight / cellSize.height)
            if roundedAdvance > 0 {
                let error = abs(rescaled - roundedAdvance) / roundedAdvance
                if error <= 0.2 { return rescaled }
                return roundedAdvance
            }
            return rescaled
        }
        if cellSize.width > 0 { return cellSize.width }
        return roundedAdvance > 0 ? roundedAdvance : 8
    }

    /// `ghostty_surface_ime_point` is top-left origin. `x` is the cursor
    /// cell midpoint; `y` is the cell bottom. Ghost text starts at the
    /// cell's leading edge so each suggested glyph shares a column with
    /// the typed grid. AppKit overlays use bottom-left origin.
    static func ghostTextOrigin(
        imeX: CGFloat,
        imeY: CGFloat,
        viewHeight: CGFloat,
        cellWidth: CGFloat
    ) -> NSPoint {
        NSPoint(x: imeX - cellWidth / 2, y: viewHeight - imeY)
    }

    /// Baseline from the bottom of an unflipped cell. Matches Ghostty's
    /// `cell_baseline` after `adjust-cell-height` recenters the face.
    static func ghostTextBaseline(cellHeight: CGFloat, font: CTFont) -> CGFloat {
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)
        let faceHeight = ascent + descent + leading
        let faceBaseline = descent + leading / 2
        return faceBaseline + (cellHeight - faceHeight) / 2
    }

    static func monospaceAdvance(font: CTFont) -> CGFloat {
        var unichar: UniChar = 0x4D // "M"
        var glyph: CGGlyph = 0
        CTFontGetGlyphsForCharacters(font, &unichar, &glyph, 1)
        var advance = CGSize.zero
        _ = CTFontGetAdvancesForGlyphs(font, .default, [glyph], &advance, 1)
        if advance.width > 0 { return advance.width }
        return CTFontGetSize(font) * 0.6
    }
}

/// A tracked single-line prompt has a fixed grid origin. Shell redraws can
/// temporarily move the live cursor backwards, so never anchor a new suffix
/// to those intermediate cursor positions.
struct GhostTextAnchor {
    let origin: NSPoint
    let cellWidth: CGFloat

    func position(for buffer: PromptBuffer, viewWidth: CGFloat) -> NSPoint? {
        guard buffer.isTracking, cellWidth > 0,
              buffer.text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7f })
        else { return nil }
        let x = origin.x + CGFloat(buffer.text.count) * cellWidth
        // Wrapped input needs shell-authoritative line geometry. Don't guess.
        guard x + cellWidth <= viewWidth else { return nil }
        return NSPoint(x: x, y: origin.y)
    }
}
