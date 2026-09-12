import AppKit

/// Reads only the styling emitted by Ghostty's VT formatter. Shell text is never
/// re-tokenized: custom highlighters and restored scrollback keep their colors.
enum CommandHeaderStyle {
    // Match Ghostty's semantic washes; the header's native material supplies frost.
    static var background: NSColor {
        SoraTheme.adaptive(light: 0xE9EDF2, dark: 0x414852).withAlphaComponent(38.0 / 255)
    }
    static var errorBackground: NSColor {
        SoraTheme.adaptive(light: 0xFCB4C3, dark: 0x6E2032).withAlphaComponent(58.0 / 255)
    }
    private static let terminalBackground = SoraTheme.adaptive(light: 0xF7F8FA, dark: 0x14161A)
    static var foreground: NSColor {
        TerminalPreferences.isLight
            ? NSColor(srgbRed: 36.0 / 255, green: 40.0 / 255, blue: 51.0 / 255, alpha: 1)
            : NSColor(srgbRed: 0.8, green: 0.8, blue: 0.8, alpha: 1)
    }
    // Match the renderer's explicit ANSI background opacity; inverse stays solid.
    static let ansiBackgroundOpacity = 209.0 / 255

    static func attributedCommand(_ snapshot: String, font: NSFont) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        var defaults = foreground
        var fg: NSColor?, bg: NSColor?, underlineColor: NSColor?
        var bold = false, italic = false, faint = false, inverse = false, invisible = false
        var underline = 0, strike = false
        let scalars = Array(snapshot.unicodeScalars)
        var index = 0

        func append(_ text: String) {
            var traits: NSFontTraitMask = []
            if bold { traits.insert(.boldFontMask) }
            if italic { traits.insert(.italicFontMask) }
            let face = NSFontManager.shared.convert(font, toHaveTrait: traits)
            var color = inverse ? (bg ?? terminalBackground) : (fg ?? defaults)
            if invisible { color = .clear }
            else if faint { color = color.withAlphaComponent(0.5) }
            var attributes: [NSAttributedString.Key: Any] = [.font: face, .foregroundColor: color]
            if inverse || bg != nil { attributes[.backgroundColor] = inverse ? (fg ?? defaults) : bg?.withAlphaComponent(ansiBackgroundOpacity) }
            if underline != 0 { attributes[.underlineStyle] = underline }
            if let underlineColor { attributes[.underlineColor] = underlineColor }
            if strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            output.append(NSAttributedString(string: text, attributes: attributes))
        }

        while index < scalars.count {
            guard scalars[index].value == 27 else {
                let start = index
                while index < scalars.count && scalars[index].value != 27 { index += 1 }
                append(String(String.UnicodeScalarView(scalars[start..<index])))
                continue
            }
            index += 1
            guard index < scalars.count else { break }
            let kind = scalars[index]; index += 1
            let start = index
            if kind == "[" {
                while index < scalars.count && !(0x40...0x7e).contains(scalars[index].value) { index += 1 }
                guard index < scalars.count else { break }
                let parameters = String(String.UnicodeScalarView(scalars[start..<index]))
                let final = scalars[index]; index += 1
                guard final == "m" else { continue }
                let parts = parameters.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
                var p = 0
                while p < parts.count {
                    let item = parts[p].split(separator: ":", omittingEmptySubsequences: false)
                    let code = Int(item.first ?? "") ?? 0
                    switch code {
                    case 0:
                        fg = nil; bg = nil; underlineColor = nil
                        bold = false; italic = false; faint = false; inverse = false
                        invisible = false; underline = 0; strike = false
                    case 1: bold = true
                    case 2: faint = true
                    case 3: italic = true
                    case 4:
                        let style = item.count > 1 ? Int(item[1]) ?? 1 : 1
                        underline = style == 0 ? 0 : style == 2 ? NSUnderlineStyle.double.rawValue : NSUnderlineStyle.single.rawValue
                        if style == 4 { underline |= NSUnderlineStyle.patternDot.rawValue }
                        if style == 5 { underline |= NSUnderlineStyle.patternDash.rawValue }
                    case 7: inverse = true
                    case 8: invisible = true
                    case 9: strike = true
                    case 22: bold = false; faint = false
                    case 23: italic = false
                    case 24: underline = 0
                    case 27: inverse = false
                    case 28: invisible = false
                    case 29: strike = false
                    case 38, 48, 58:
                        // Ghostty resolves indexed colors to RGB before export.
                        if p + 4 < parts.count, parts[p + 1] == "2",
                           let r = Double(parts[p + 2]), let g = Double(parts[p + 3]), let b = Double(parts[p + 4]) {
                            let color = NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
                            if code == 38 { fg = color }
                            if code == 48 { bg = color }
                            if code == 58 { underlineColor = color }
                            p += 4
                        }
                    case 39: fg = nil
                    case 49: bg = nil
                    case 59: underlineColor = nil
                    default: break
                    }
                    p += 1
                }
            } else if kind == "]" {
                while index < scalars.count && scalars[index].value != 7 && scalars[index].value != 27 { index += 1 }
                let osc = String(String.UnicodeScalarView(scalars[start..<index]))
                if osc.hasPrefix("10;rgb:") {
                    let rgb = osc.dropFirst(7).split(separator: "/").compactMap { UInt64($0, radix: 16).map { Double($0) } }
                    if rgb.count == 3 { defaults = NSColor(srgbRed: rgb[0] / 255, green: rgb[1] / 255, blue: rgb[2] / 255, alpha: 1) }
                }
                if index < scalars.count {
                    let escape = scalars[index].value == 27
                    index += 1
                    if escape && index < scalars.count && scalars[index] == "\\" { index += 1 }
                }
            }
        }
        // Trim terminal padding without discarding attributes or Unicode offsets.
        let text = output.string as NSString
        let visible = text.rangeOfCharacter(from: .whitespacesAndNewlines.inverted)
        guard visible.location != NSNotFound else { return NSAttributedString(string: "") }
        let last = text.rangeOfCharacter(from: .whitespacesAndNewlines.inverted, options: .backwards)
        return output.attributedSubstring(from: NSRange(location: visible.location, length: NSMaxRange(last) - visible.location))
    }

    static func singleLine(_ command: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: command)
        for index in (0..<result.length).reversed() where (result.string as NSString).character(at: index) == 10 {
            result.replaceCharacters(in: NSRange(location: index, length: 1), with: " ↵ ")
        }
        return result
    }
}
