import Foundation
import Testing
@testable import RhinoCore

/// `Reindenter`: indentation is tidied and nothing else changes.
@Suite struct ReindenterTests {
    @Test func indentsByBrackets() {
        let messy = """
        const rows = await get(url, {
        query: { page: 1,
              size: 10 },
            });
              for (const row of rows.data) {
        if (row.ok) {
                output.log(row.name);\t
        } else {
        skipped.push([
        row.id,
        row.reason,
        ]);
        }
        }
        """
        #expect(Reindenter.reindent(messy) == """
        const rows = await get(url, {
          query: { page: 1,
            size: 10 },
        });
        for (const row of rows.data) {
          if (row.ok) {
            output.log(row.name);
          } else {
            skipped.push([
              row.id,
              row.reason,
            ]);
          }
        }

        """)
    }

    @Test func aCallbackIsOneLevelNotTwo() {
        // Two brackets open on one line; what is inside goes one level in, and `});` closes both.
        #expect(Reindenter.reindent("items.forEach(function (item) {\noutput.log(item);\n});\ndone();") == "items.forEach(function (item) {\n  output.log(item);\n});\ndone();\n")
        #expect(Reindenter.reindent("call({\na: 1,\n}, [\n2,\n]);") == "call({\n  a: 1,\n}, [\n  2,\n]);\n")
    }

    @Test func chainsTernariesAndSwitch() {
        #expect(Reindenter.reindent("const names = users\n.filter((u) => u.active)\n.map((u) => u.name);\nconst spread = [\n...names,\n.5,\n];") == "const names = users\n  .filter((u) => u.active)\n  .map((u) => u.name);\nconst spread = [\n  ...names,\n  .5,\n];\n")
        #expect(Reindenter.reindent("const label = count === 1\n? \"one\"\n: \"many\";") == "const label = count === 1\n  ? \"one\"\n  : \"many\";\n")
        #expect(Reindenter.reindent("switch (kind) {\ncase \"a\":\nfirst();\nbreak;\ndefault:\nrest({\nx: 1,\n});\n}\nafter();") == "switch (kind) {\n  case \"a\":\n    first();\n    break;\n  default:\n    rest({\n      x: 1,\n    });\n}\nafter();\n")
    }

    @Test func leavesStringsCommentsAndRegexesAlone() {
        // Brackets in text are not structure, and a template literal's lines are data.
        let source = "const text = `Dear ${name},\n      thanks for {everything}.\n   )`;\n   const pattern = /[({]+/;\n      const quote = \"}\"; // }\n   /*\n    * a { comment\n      as written   \n    */\n   done();"
        #expect(Reindenter.reindent(source) == "const text = `Dear ${name},\n      thanks for {everything}.\n   )`;\nconst pattern = /[({]+/;\nconst quote = \"}\"; // }\n/*\n * a { comment\n      as written\n */\ndone();\n")
    }

    @Test func survivesBrokenCodeAndOddEndings() {
        #expect(Reindenter.reindent("") == "")
        #expect(Reindenter.reindent("}\n)\nfoo(") == "}\n)\nfoo(\n")
        #expect(Reindenter.reindent("if (a) {\r\n\tb();\r\n}\r\n\r\n\r\n") == "if (a) {\n  b();\n}\n")
        #expect(Reindenter.reindent("a();\n\n\nb();") == "a();\n\n\nb();\n")
    }

    @Test func changesOnlyWhitespaceAndSettles() throws {
        for (id, source) in Examples.all {
            let tidy = Reindenter.reindent(source)
            // The same characters in the same order, spaces aside: nothing was rewritten.
            #expect(tidy.filter { !$0.isWhitespace } == source.filter { !$0.isWhitespace }, "\(id)")
            #expect(ScriptCompiler.syntaxProblem(in: tidy) == nil, "\(id)")
            // Doing it again changes nothing.
            #expect(Reindenter.reindent(tidy) == tidy, "\(id)")
            // The examples ship tidy: Re-Indent leaves them as they are.
            #expect(tidy == source, "\(id) is not indented the way Re-Indent would")
        }
    }
}
