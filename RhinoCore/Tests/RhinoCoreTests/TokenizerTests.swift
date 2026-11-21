import Foundation
import Testing
@testable import RhinoCore

/// `JavaScriptTokenizer`: classifying script code for syntax highlighting.
@Suite struct TokenizerTests {
    /// The source text each token of one kind covers, in order.
    private func words(_ kind: SyntaxToken.Kind, in source: String) -> [String] {
        let units = Array(source.utf16)
        return JavaScriptTokenizer.tokens(in: source)
            .filter { $0.kind == kind }
            .map { String(utf16CodeUnits: Array(units[$0.range]), count: $0.range.count) }
    }

    @Test func classifiesScriptCode() {
        let source = """
        // @name Demo script
        /* block
           comment */
        const rows = await input.file("Orders", { ext: 'csv' });
        if (rows.length > 10.5 && !done) output.log(`Got ${rows.length}`, parse(rows), true);
        """
        #expect(words(.comment, in: source) == ["// @name Demo script", "/* block\n   comment */"])
        #expect(words(.tag, in: source) == ["@name"])
        #expect(words(.keyword, in: source) == ["const", "await", "if"])
        #expect(words(.builtin, in: source) == ["input", "output"])
        #expect(words(.string, in: source) == ["\"Orders\"", "'csv'", "`Got ${rows.length}`"])
        #expect(words(.number, in: source) == ["10.5"])
        #expect(words(.literal, in: source) == ["true"])
        // `file` and `log` are methods here, not the globals of the same name.
        #expect(words(.call, in: source) == ["file", "log", "parse"])
    }

    @Test func tellsRegexFromDivision() {
        #expect(words(.string, in: #"name.replace(/\.csv$/i, ".json")"#) == [#"/\.csv$/i"#, "\".json\""])
        #expect(words(.string, in: #"const quote = /["'/]/g;"#) == [#"/["'/]/g"#])
        #expect(words(.string, in: "const half = total / 2 / count;") == [])
        #expect(words(.number, in: "const half = total / 2 / count;") == ["2"])
    }

    @Test func survivesUnfinishedCode() {
        #expect(words(.string, in: "const a = \"open\nconst b = 1;") == ["\"open"])
        #expect(words(.comment, in: "let x; /* never closed") == ["/* never closed"])
        #expect(words(.string, in: "`template without end").count == 1)
        #expect(JavaScriptTokenizer.tokens(in: "").isEmpty)
        // Offsets are UTF-16, so text after an emoji still lines up.
        #expect(words(.keyword, in: "const s = \"🙂\"; return s;") == ["const", "return"])
    }
}
