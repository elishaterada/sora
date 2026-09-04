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
    /// Use the font advance first (Ghostty's `cell_width` is the face width).
    /// If CELL_SIZE is available, prefer the rescaled width when it agrees
    /// with the font within 15% — that keeps the half-cell IME offset exact.
    static func ghostTextCellWidth(
        imeHeight: CGFloat,
        cellSize: NSSize,
        font: CTFont
    ) -> CGFloat {
        let advance = monospaceAdvance(font: font)
        if imeHeight > 0, cellSize.width > 0, cellSize.height > 0 {
            let rescaled = cellSize.width * (imeHeight / cellSize.height)
            if advance > 0 {
                let delta = abs(rescaled - advance) / advance
                if delta <= 0.15 { return rescaled }
                return advance
            }
            return rescaled
        }
        return advance > 0 ? advance : 8
    }

    /// `ghostty_surface_ime_point` is top-left origin. `x` is the cursor
    /// cell midpoint; `y` is the cell bottom. Ghost text starts at the
    /// cell's leading edge. AppKit overlays use bottom-left origin.
    static func ghostTextOrigin(
        imeX: CGFloat,
        imeY: CGFloat,
        viewHeight: CGFloat,
        cellWidth: CGFloat
    ) -> NSPoint {
        NSPoint(x: imeX - cellWidth / 2, y: viewHeight - imeY)
    }

    /// Baseline from the bottom of an unflipped cell. Matches Ghostty's
    /// vertically centered face inside `adjust-cell-height` growth.
    static func ghostTextBaseline(cellHeight: CGFloat, font: CTFont) -> CGFloat {
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        // Leading cancels when the face is centered; keep the em-box center.
        return (cellHeight - ascent + descent) / 2
    }

    static func monospaceAdvance(font: CTFont) -> CGFloat {
        let glyph = CTFontGetGlyphWithName(font, "M" as CFString)
        var advance = CGSize.zero
        _ = CTFontGetAdvancesForGlyphs(font, .default, [glyph], &advance, 1)
        if advance.width > 0 { return advance.width }
        return CTFontGetSize(font) * 0.6
    }
}
