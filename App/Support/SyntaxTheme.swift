import AppKit
import RhinoCore
import SwiftUI

/// Colors script source in the editor. The tokenizer lives in RhinoCore; this
/// only decides what each kind of token looks like.
enum SyntaxTheme {
    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.textColor]
    }

    private static let comment = dynamicColor(light: 0x5D6C79, dark: 0x7F8C98)
    private static let string = dynamicColor(light: 0xC41A16, dark: 0xFC6A5D)
    private static let number = dynamicColor(light: 0x1C00CF, dark: 0xD0BF69)
    private static let keyword = dynamicColor(light: 0x9B2393, dark: 0xFC5FA3)
    private static let builtin = dynamicColor(light: 0x0B4F79, dark: 0x5DD8FF)
    private static let call = dynamicColor(light: 0x326D74, dark: 0x67B7A4)

    static func color(for kind: SyntaxToken.Kind) -> NSColor {
        switch kind {
        case .comment: comment
        case .string: string
        case .number: number
        case .keyword, .literal: keyword
        case .builtin, .tag: builtin
        case .call: call
        }
    }

    /// JSON text with its keys, strings, numbers and literals colored, for
    /// showing a result outside the editor.
    static func json(_ text: String) -> AttributedString {
        let units = Array(text.utf16)
        func piece(_ range: Range<Int>) -> AttributedString {
            AttributedString(String(decoding: units[range], as: UTF16.self))
        }

        var result = AttributedString()
        var position = 0
        for token in JavaScriptTokenizer.tokens(in: text) {
            if token.range.lowerBound > position {
                result += piece(position..<token.range.lowerBound)
            }
            // A string followed by a colon is a key.
            var next = token.range.upperBound
            while next < units.count, units[next] == UInt16(UInt8(ascii: " ")) { next += 1 }
            let isKey = token.kind == .string && next < units.count && units[next] == UInt16(UInt8(ascii: ":"))

            var colored = piece(token.range)
            colored.foregroundColor = Color(nsColor: isKey ? builtin : color(for: token.kind))
            result += colored
            position = token.range.upperBound
        }
        if position < units.count {
            result += piece(position..<units.count)
        }
        return result
    }

    /// Recolors the whole document. Scripts are single small files, so this is
    /// cheap enough to do on every edit.
    static func apply(to textView: NSTextView) {
        // Leave text alone while an input method is still composing it.
        guard let storage = textView.textStorage, !textView.hasMarkedText() else { return }
        let tokens = JavaScriptTokenizer.tokens(in: storage.string)

        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: NSRange(location: 0, length: storage.length))
        for token in tokens {
            let range = NSRange(location: token.range.lowerBound, length: token.range.count)
            storage.addAttribute(.foregroundColor, value: color(for: token.kind), range: range)
        }
        storage.endEditing()
    }
}

/// A color that follows the window's light or dark appearance.
private nonisolated func dynamicColor(light: UInt32, dark: UInt32) -> NSColor {
    NSColor(name: nil) { appearance in
        let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        return NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
