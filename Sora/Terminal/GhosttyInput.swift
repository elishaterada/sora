import AppKit

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

    /// `ghostty_surface_ime_point` is top-left origin. `x` is the caret's
    /// leading edge (bar cursor), `y` is the cell bottom. AppKit overlays
    /// use bottom-left origin.
    static func ghostTextOrigin(
        imeX: CGFloat,
        imeY: CGFloat,
        viewHeight: CGFloat
    ) -> NSPoint {
        NSPoint(x: imeX, y: viewHeight - imeY)
    }

    /// Baseline inside an unflipped cell, matching Ghostty's vertically
    /// centered glyphs when `adjust-cell-height` adds extra leading.
    static func ghostTextBaseline(cellHeight: CGFloat, font: NSFont) -> CGFloat {
        let extra = cellHeight - font.ascender + font.descender
        return -font.descender + extra / 2
    }
}
