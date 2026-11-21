import Foundation

/// A piece of script source worth coloring. Plain identifiers, punctuation and
/// whitespace produce no token.
public struct SyntaxToken: Hashable, Sendable {
    public enum Kind: Sendable {
        case comment
        /// An `@name`-style tag in the script's header comment.
        case tag
        /// String, template literal or regular expression.
        case string
        case number
        case keyword
        /// `true`, `null`, `this` and friends.
        case literal
        /// One of the script globals: `input`, `output`, `get`, …
        case builtin
        /// A name that is being called: `parse(`.
        case call
    }

    public let kind: Kind
    /// UTF-16 offsets into the source, which is what text views work in.
    public let range: Range<Int>
}

/// A small JavaScript lexer for syntax highlighting. It only needs to be right
/// about where comments, strings and words start and end; it never fails, and
/// treats unterminated strings and comments as running to the end of the line
/// or file.
public enum JavaScriptTokenizer {
    private static let keywords: Set<String> = [
        "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default",
        "delete", "do", "else", "export", "extends", "finally", "for", "function", "if", "import", "in",
        "instanceof", "let", "new", "of", "return", "static", "switch", "throw", "try", "typeof", "var",
        "void", "while", "with", "yield",
    ]
    private static let literals: Set<String> = ["true", "false", "null", "undefined", "NaN", "Infinity", "this", "super"]
    private static let builtins = Set(ScriptCompiler.globals)

    public static func tokens(in source: String) -> [SyntaxToken] {
        let text = Array(source.utf16)
        let count = text.count
        var tokens: [SyntaxToken] = []
        var index = 0
        // Whether a `/` at this point starts a regular expression rather than a division.
        var regexAllowed = true
        var afterDot = false

        func at(_ offset: Int) -> UInt16? {
            offset < count ? text[offset] : nil
        }
        func isIdentifierStart(_ unit: UInt16) -> Bool {
            unit == ascii("_") || unit == ascii("$") || unit > 127
                || (unit >= ascii("a") && unit <= ascii("z")) || (unit >= ascii("A") && unit <= ascii("Z"))
        }
        func isDigit(_ unit: UInt16) -> Bool {
            unit >= ascii("0") && unit <= ascii("9")
        }
        func isNewline(_ unit: UInt16) -> Bool {
            unit == ascii("\n") || unit == ascii("\r")
        }
        func add(_ kind: SyntaxToken.Kind, _ start: Int, _ end: Int) {
            tokens.append(SyntaxToken(kind: kind, range: start..<end))
        }

        while index < count {
            let unit = text[index]
            let start = index

            if unit == ascii(" ") || unit == ascii("\t") || isNewline(unit) {
                index += 1
                continue
            }

            // Comments
            if unit == ascii("/"), at(index + 1) == ascii("/") {
                while index < count, !isNewline(text[index]) { index += 1 }
                add(.comment, start, index)
                // `// @name value`: color the tag on top of the comment.
                var cursor = start + 2
                while cursor < index, text[cursor] == ascii(" ") || text[cursor] == ascii("\t") { cursor += 1 }
                if cursor < index, text[cursor] == ascii("@") {
                    var end = cursor + 1
                    while end < index, isIdentifierStart(text[end]) { end += 1 }
                    if end > cursor + 1 { add(.tag, cursor, end) }
                }
                continue
            }
            if unit == ascii("/"), at(index + 1) == ascii("*") {
                index += 2
                while index < count, !(text[index] == ascii("*") && at(index + 1) == ascii("/")) { index += 1 }
                index = min(index + 2, count)
                add(.comment, start, index)
                continue
            }

            // Strings and template literals
            if unit == ascii("\"") || unit == ascii("'") || unit == ascii("`") {
                let isTemplate = unit == ascii("`")
                index += 1
                while index < count, text[index] != unit {
                    if text[index] == ascii("\\") { index += 1 }
                    else if !isTemplate, isNewline(text[index]) { break }
                    index += 1
                }
                // Take the closing quote, but not the newline an unfinished string stopped at.
                index = min(index, count)
                if at(index) == unit { index += 1 }
                add(.string, start, index)
                regexAllowed = false
                afterDot = false
                continue
            }

            // Regular expressions
            if unit == ascii("/"), regexAllowed {
                var inClass = false
                index += 1
                while index < count, !isNewline(text[index]), inClass || text[index] != ascii("/") {
                    if text[index] == ascii("\\") { index += 1 }
                    else if text[index] == ascii("[") { inClass = true }
                    else if text[index] == ascii("]") { inClass = false }
                    index += 1
                }
                index = min(index, count)
                if at(index) == ascii("/") { index += 1 }
                while index < count, isIdentifierStart(text[index]) { index += 1 }
                add(.string, start, index)
                regexAllowed = false
                afterDot = false
                continue
            }

            // Numbers
            if isDigit(unit) || (unit == ascii(".") && at(index + 1).map(isDigit) == true) {
                index += 1
                while index < count, isDigit(text[index]) || isIdentifierStart(text[index]) || text[index] == ascii(".") { index += 1 }
                add(.number, start, index)
                regexAllowed = false
                afterDot = false
                continue
            }

            // Words
            if isIdentifierStart(unit) {
                index += 1
                while index < count, isIdentifierStart(text[index]) || isDigit(text[index]) { index += 1 }
                let word = String(utf16CodeUnits: Array(text[start..<index]), count: index - start)

                var next = index
                while next < count, text[next] == ascii(" ") || text[next] == ascii("\t") { next += 1 }
                let isCalled = at(next) == ascii("(")

                // After a dot a word is a property name, whatever it spells.
                if afterDot {
                    if isCalled { add(.call, start, index) }
                    regexAllowed = false
                } else if keywords.contains(word) {
                    add(.keyword, start, index)
                    regexAllowed = true
                } else if literals.contains(word) {
                    add(.literal, start, index)
                    regexAllowed = false
                } else if builtins.contains(word) {
                    add(.builtin, start, index)
                    regexAllowed = false
                } else {
                    if isCalled { add(.call, start, index) }
                    regexAllowed = false
                }
                afterDot = false
                continue
            }

            // Punctuation
            afterDot = unit == ascii(".")
            regexAllowed = !(unit == ascii(")") || unit == ascii("]") || unit == ascii("}"))
            index += 1
        }
        return tokens
    }

    private static func ascii(_ character: Character) -> UInt16 {
        UInt16(character.asciiValue ?? 0)
    }
}
