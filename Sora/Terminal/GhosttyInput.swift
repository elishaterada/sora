import AppKit
import GhosttyKit

enum GhosttyInput {
    static func mods(from flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(mods)
    }

    static func keyEvent(
        from event: NSEvent,
        action: ghostty_input_action_e
    ) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        key.text = nil
        key.composing = false
        key.mods = mods(from: event.modifierFlags)
        key.consumed_mods = mods(from: event.modifierFlags.subtracting([.control, .command]))
        key.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp,
           let chars = event.characters(byApplyingModifiers: []),
           let codepoint = chars.unicodeScalars.first {
            key.unshifted_codepoint = codepoint.value
        }
        return key
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

    static func scrollMods(precision: Bool) -> ghostty_input_scroll_mods_t {
        precision ? 1 : 0
    }

    /// libghostty mouse coordinates are top-left origin. AppKit view points
    /// (unflipped) are bottom-left origin.
    static func surfaceMousePoint(viewPoint: NSPoint, viewHeight: CGFloat) -> NSPoint {
        NSPoint(x: viewPoint.x, y: viewHeight - viewPoint.y)
    }
}
