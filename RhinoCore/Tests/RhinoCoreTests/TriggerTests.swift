import Foundation
import Testing
@testable import RhinoCore

/// What starts a run and checks a script first: syntax checks, watched folders, data handed in, and the trigger a record keeps.
@Suite struct TriggerTests {
    @Test func findsMistakesWithoutRunningAnything() {
        #expect(ScriptCompiler.syntaxProblem(in: "output.log('fine');\nawait sleep(1);") == nil)
        // Using something that does not exist is not a syntax matter; it parses.
        #expect(ScriptCompiler.syntaxProblem(in: "nope();") == nil)

        let broken = ScriptCompiler.syntaxProblem(in: "output.log('one');\nconst a = ;\noutput.log('three');")
        #expect(broken?.contains("SyntaxError") == true)
        #expect(broken?.contains("(line 2)") == true)

        let imported = ScriptCompiler.syntaxProblem(in: "import fs from 'fs';")
        #expect(imported?.contains("`import` is not supported") == true)
        #expect(ScriptCompiler.syntaxProblem(in: "export const a = 1;")?.contains("`export` is not needed") == true)

        // The words alone are not statements: a prompt or a comment may start a line with them.
        let harmless = "const prompt = `Please\nimport the rows and\nexport them as CSV`;\n/*\nexport notes\n*/\noutput.log(prompt);"
        #expect(ScriptCompiler.syntaxProblem(in: harmless) == nil)
    }

    @Test func readsAWatchedFolder() throws {
        let home = NSHomeDirectory()
        let all = try FolderWatch("~/Downloads")
        #expect(all.folder.path(percentEncoded: false) == home + "/Downloads/")
        #expect(all.pattern == nil)
        #expect(all.matches(URL(filePath: home + "/Downloads/report.pdf")))
        #expect(!all.matches(URL(filePath: home + "/Downloads/.DS_Store")))
        // A browser's half-finished download is not a file yet.
        #expect(!all.matches(URL(filePath: home + "/Downloads/report.pdf.crdownload")))
        #expect(!all.matches(URL(filePath: home + "/Downloads/Unconfirmed 1.download")))

        let pdfs = try FolderWatch("  /Users/Shared/In box/*.pdf ")
        #expect(pdfs.folder.path(percentEncoded: false) == "/Users/Shared/In box/")
        #expect(pdfs.pattern == "*.pdf")
        #expect(pdfs.matches(URL(filePath: "/Users/Shared/In box/Invoice 12.PDF")))
        #expect(!pdfs.matches(URL(filePath: "/Users/Shared/In box/notes.txt")))

        #expect(throws: FolderWatch.ParseError.self) { try FolderWatch("") }
        #expect(throws: FolderWatch.ParseError.self) { try FolderWatch("Downloads") }
        #expect(throws: FolderWatch.ParseError.self) { try FolderWatch("~/*/inbox/*.pdf") }
        #expect(ScriptHeader.parse("// @name X\n// @watch ~/Downloads/*.csv\n")["watch"] == "~/Downloads/*.csv")
    }

    @Test func aRunCanBeHandedDataFromOutside() async throws {
        let (engine, _) = makeEngine(["m": "output.json({ got: input.data });"])

        let object = await engine.run("m", data: #"{"city":"Riga","n":2}"#, events: Recorder().record)
        #expect((try json(object.resultJSON) as? [String: [String: Any]])?["got"]?["city"] as? String == "Riga")

        // Text that is not JSON arrives as the text it is.
        let text = await engine.run("m", data: "just words", events: Recorder().record)
        #expect((try json(text.resultJSON) as? [String: String])?["got"] == "just words")

        let nothing = await engine.run("m", events: Recorder().record)
        #expect((try json(nothing.resultJSON) as? [String: Any])?["got"] is NSNull)
    }

    @Test func aRecordRemembersWhatStartedIt() throws {
        let summary = try JSONDecoder().decode(RunSummary.self, from: Data(#"{"outputDirectory":"file:///tmp/x/","startedAt":0,"finishedAt":1}"#.utf8))
        let record = RunRecord(id: UUID(), script: "m", isScheduled: true, trigger: "folder", summary: summary, runs: [], items: [])
        #expect(try RunRecord(data: record.encoded()).trigger == "folder")

        // Records from before triggers were kept still read; they name the script "module", as stored records do.
        let old = #"{"id":"\#(UUID().uuidString)","module":"m","isScheduled":true,"summary":{"outputDirectory":"file:///tmp/x/","startedAt":0,"finishedAt":1},"runs":[],"items":[]}"#
        let restored = try RunRecord(data: Data(old.utf8))
        #expect(restored.trigger == nil)
        #expect(restored.isScheduled)
    }
}
