import AppKit
import GhosttyKit

extension GhosttyInput {
    static func mods(from flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        ghostty_input_mods_e(modBits(from: flags))
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

    static func scrollMods(precision: Bool) -> ghostty_input_scroll_mods_t {
        precision ? 1 : 0
    }
}
