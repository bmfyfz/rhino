import Foundation

/// Tidies a script's indentation, and nothing else.
///
/// Every line is indented by how deeply it sits inside brackets, two spaces a
/// level, and spaces at the ends of lines are dropped. No line is joined,
/// split or otherwise rewritten, so the code means exactly what it did. Text
/// inside template literals is left as it is, since there the spaces are
/// part of the string.
public enum Reindenter {
    /// One level of indentation, the same as the editor's Tab key.
    public static let unit = "  "

    public static func reindent(_ source: String) -> String {
        let text = Array(source.utf16)
        guard !text.isEmpty else { return source }

        // Brackets inside strings and comments are not structure.
        enum Cover: UInt8 { case code, string, comment }
        var cover = [Cover](repeating: .code, count: text.count)
        for token in JavaScriptTokenizer.tokens(in: source) {
            let kind: Cover
            switch token.kind {
            case .string: kind = .string
            case .comment: kind = .comment
            default: continue
            }
            for index in token.range where index < text.count { cover[index] = kind }
        }

        let newline = UInt16(UInt8(ascii: "\n"))
        func isSpace(_ unit: UInt16) -> Bool { unit == 0x20 || unit == 0x09 || unit == 0x0D }
        func isOpener(_ unit: UInt16) -> Bool { unit == UInt16(UInt8(ascii: "(")) || unit == UInt16(UInt8(ascii: "[")) || unit == UInt16(UInt8(ascii: "{")) }
        func isCloser(_ unit: UInt16) -> Bool { unit == UInt16(UInt8(ascii: ")")) || unit == UInt16(UInt8(ascii: "]")) || unit == UInt16(UInt8(ascii: "}")) }

        /// The open brackets, each with the level of the line it is on: what
        /// is inside sits one level deeper, and the closing bracket lines up
        /// with that line again.
        var open: [Int] = []
        /// How many brackets were open where a `switch` body's `case` was
        /// seen: the statements under a `case` go one level deeper than it.
        var cases: Set<Int> = []
        var lines: [String] = []

        var start = 0
        while start <= text.count {
            var end = start
            while end < text.count, text[end] != newline { end += 1 }
            defer { start = end + 1 }

            // A line that begins inside a template literal or a block comment
            // belongs to it. The string is kept to the letter; a comment only
            // loses the spaces at its end.
            let continues: Cover = start > 0 && start < text.count && cover[start] != .code && cover[start - 1] == cover[start] ? cover[start] : .code

            var first = start
            while first < end, isSpace(text[first]) { first += 1 }
            var last = end
            while last > first, isSpace(text[last - 1]) { last -= 1 }

            var level = 0
            var scan = first
            if continues == .code {
                // Closing brackets at the start line the line up with the one that opened them.
                var closed: Int?
                while scan < last, isCloser(text[scan]), cover[scan] == .code {
                    closed = open.popLast() ?? closed
                    scan += 1
                    while scan < last, isSpace(text[scan]) { scan += 1 }
                }
                cases = cases.filter { $0 <= open.count }
                let word = String(utf16CodeUnits: Array(text[first..<last].prefix(9)), count: min(9, last - first))
                let isLabel = word.hasPrefix("case ") || word.hasPrefix("case(") || word.hasPrefix("default:") || word.hasPrefix("default :")
                if let closed {
                    level = closed
                } else {
                    level = (open.last.map { $0 + 1 } ?? 0) + (cases.contains(open.count) && !isLabel ? 1 : 0)
                    // A line that carries on the one before: `.then(…)`, `? a`, `: b`.
                    if !isLabel, first < last {
                        let next = first + 1 < last ? text[first + 1] : 0
                        let isChain = text[first] == UInt16(UInt8(ascii: ".")) && next != UInt16(UInt8(ascii: ".")) && !(next >= 0x30 && next <= 0x39)
                        let isTernary = (text[first] == UInt16(UInt8(ascii: "?")) || text[first] == UInt16(UInt8(ascii: ":"))) && next == 0x20
                        if isChain || isTernary { level += 1 }
                    }
                }
                if isLabel { cases.insert(open.count) }
            }

            // What the rest of the line opens and closes decides the lines after it.
            while scan < last {
                if cover[scan] == .code {
                    if isOpener(text[scan]) {
                        open.append(level)
                    } else if isCloser(text[scan]) {
                        _ = open.popLast()
                        cases = cases.filter { $0 <= open.count }
                    }
                }
                scan += 1
            }

            let body = String(utf16CodeUnits: Array(text[first..<last]), count: last - first)
            switch continues {
            case .string:
                lines.append(String(utf16CodeUnits: Array(text[start..<end]), count: end - start))
            case .comment:
                // ` * like this` keeps its star under the comment's opening.
                let whole = String(utf16CodeUnits: Array(text[start..<last]), count: last - start)
                let depth = (open.last.map { $0 + 1 } ?? 0) + (cases.contains(open.count) ? 1 : 0)
                lines.append(body.hasPrefix("*") ? String(repeating: unit, count: depth) + " " + body : whole)
            case .code:
                lines.append(body.isEmpty ? "" : String(repeating: unit, count: level) + body)
            }
            if end == text.count { break }
        }

        // Exactly one line break at the end.
        while lines.count > 1, lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n") + "\n"
    }
}
