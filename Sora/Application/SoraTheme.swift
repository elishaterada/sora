import SwiftUI

/// Session chrome colors. Keep in lockstep with `Resources/sora.ghostty`.
enum SoraTheme {
    static let ink = Color(red: 0.086, green: 0.078, blue: 0.102)
    static let sidebar = Color(red: 0.071, green: 0.063, blue: 0.090)
    static let surface = Color(red: 0.118, green: 0.110, blue: 0.141)
    static let hairline = Color(red: 0.22, green: 0.20, blue: 0.24)
    static let text = Color(red: 0.937, green: 0.910, blue: 0.863)
    static let muted = Color(red: 0.659, green: 0.624, blue: 0.576)
    static let copper = Color(red: 0.878, green: 0.631, blue: 0.353)
    static let sage = Color(red: 0.561, green: 0.722, blue: 0.580)

    static var nsInk: NSColor {
        NSColor(red: 0.086, green: 0.078, blue: 0.102, alpha: 1)
    }
}
