import RhinoCore
import SwiftUI

extension Shortcut {
    var keyboardShortcut: KeyboardShortcut {
        var flags: EventModifiers = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return KeyboardShortcut(KeyEquivalent(key), modifiers: flags)
    }
}

extension TimeInterval {
    /// "320 ms" or "1.24 s".
    var formattedDuration: String {
        self < 1
            ? "\(Int((self * 1000).rounded())) ms"
            : "\(formatted(.number.precision(.fractionLength(2)))) s"
    }
}
