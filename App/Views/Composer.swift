import SwiftUI

// The input bar the app uses wherever something is typed and sent: asking
// the AI above the code, and answering a script's question in the console.
// One rounded glass field with what is being entered, a filled pill at its
// end that sends it (as in Messages), and, where there is something to call
// off, a round button before it. Icons only; each says what it does on hover.

/// The field: content on the left, the action button at the trailing end.
struct Composer<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        // Bottom-aligned, so the button stays put when the text grows to several lines.
        HStack(alignment: .bottom, spacing: 8) {
            content
        }
        .padding(.leading, 16)
        .padding(.trailing, ComposerMetrics.inset)
        .padding(.vertical, ComposerMetrics.inset)
        // A capsule at one line that stays round, not pill-shaped, at five.
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Self.height / 2, style: .continuous))
    }

    /// The bar's height with one line of text.
    static var height: CGFloat { ComposerMetrics.height }
}

enum ComposerMetrics {
    static let height: CGFloat = 40
    /// The action button: a pill half as tall as the field and wider than
    /// tall, with the same space above, below and after it.
    static let action = CGSize(width: 34, height: 22)
    static var inset: CGFloat { (height - action.height) / 2 }
    /// The cancel button beside the field, a little smaller than the field is tall.
    static let cancel: CGFloat = 32
}

extension View {
    /// Lines a label or text field up with the composer's round buttons.
    func composerRow() -> some View {
        frame(minHeight: ComposerMetrics.action.height)
    }
}

/// The filled pill at the end of a composer: send, stop, choose.
struct ComposerActionButton: View {
    let title: String
    var symbol = "arrow.up"
    var shortcut: KeyboardShortcut?
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(isEnabled ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
                .frame(width: ComposerMetrics.action.width, height: ComposerMetrics.action.height)
                .background(isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut)
        .accessibilityLabel(title)
        .help(title)
    }
}

/// The round button beside a composer that calls the whole thing off.
struct ComposerCancelButton: View {
    let title: String
    var shortcut: KeyboardShortcut?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: ComposerMetrics.cancel, height: ComposerMetrics.cancel)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .keyboardShortcut(shortcut)
        .accessibilityLabel(title)
        .help(title)
    }
}
