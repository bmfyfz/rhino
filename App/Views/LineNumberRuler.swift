import AppKit

/// The line numbers beside the code. A line that wraps has one number, at its
/// first row, and the number of the line the caret is on stands out.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        // Without this a ruler may paint over the text it stands beside.
        clipsToBounds = true
        fitThickness()

        scrollView.contentView.postsBoundsChangedNotifications = true
        textView.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        center.addObserver(self, selector: #selector(redraw), name: NSView.frameDidChangeNotification, object: textView)
        center.addObserver(self, selector: #selector(redraw), name: NSTextView.didChangeSelectionNotification, object: textView)
        center.addObserver(self, selector: #selector(textChanged), name: NSText.didChangeNotification, object: textView)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("LineNumberRuler is created in code")
    }

    /// The text is different: there may be more digits to make room for.
    /// Typing announces itself; text set from outside has to say so here.
    @objc func textChanged() {
        fitThickness()
        needsDisplay = true
    }

    @objc private func redraw() {
        needsDisplay = true
    }

    /// Wide enough for the highest line number, and for two digits at least
    /// so that the code does not jump sideways at line 10.
    private func fitThickness() {
        let lines = (textView?.string.utf16.count { $0 == 0x0A } ?? 0) + 1
        let digits = max(2, String(lines).count)
        let digitWidth = ("8" as NSString).size(withAttributes: [.font: font]).width
        let width = ceil(digitWidth * CGFloat(digits)) + 18
        if ruleThickness != width { ruleThickness = width }
    }

    override func draw(_ dirtyRect: NSRect) {
        // No background and no edge line of the ruler's own: the numbers
        // stand on whatever the editor stands on.
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let content = textView.string as NSString
        let origin = textView.textContainerOrigin
        let caretLine = content.lineRange(for: NSRange(location: min(textView.selectedRange().location, content.length), length: 0)).location

        func draw(_ number: Int, baseline: CGFloat, isCurrent: Bool) {
            let y = convert(NSPoint(x: 0, y: baseline + origin.y), from: textView).y
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: isCurrent ? NSColor.labelColor : NSColor.tertiaryLabelColor,
            ]
            let text = "\(number)" as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: bounds.width - size.width - 6, y: y - font.ascender), withAttributes: attributes)
        }

        // Only the lines on screen are numbered, starting at the first one
        // that shows, which may begin above the visible part.
        let shown = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layoutManager.glyphRange(forBoundingRect: shown, in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var index = content.lineRange(for: NSRange(location: characters.location, length: 0)).location
        var number = 1
        var scan = 0
        while scan < index {
            scan = NSMaxRange(content.lineRange(for: NSRange(location: scan, length: 0)))
            number += 1
        }

        while index < content.length, index <= NSMaxRange(characters) {
            let line = content.lineRange(for: NSRange(location: index, length: 0))
            let glyph = layoutManager.glyphIndexForCharacter(at: index)
            let row = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            draw(number, baseline: row.minY + layoutManager.location(forGlyphAt: glyph).y, isCurrent: line.location == caretLine)
            index = NSMaxRange(line)
            number += 1
        }

        // The empty line after a final line break, or an empty script, has
        // no characters of its own; the layout keeps a place for it.
        let endsWithBreak = content.length == 0 || content.character(at: content.length - 1) == 0x0A
        let last = layoutManager.extraLineFragmentRect
        if index >= content.length, endsWithBreak, last.height > 0 {
            let codeFont = textView.font ?? font
            draw(number, baseline: last.minY + layoutManager.defaultBaselineOffset(for: codeFont), isCurrent: caretLine == content.length)
        }
    }
}
