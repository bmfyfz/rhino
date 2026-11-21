import Foundation
import Testing
@testable import RhinoCore

/// What a script is given through `input`: dropped files, file prompts, and questions with typed answers.
@Suite struct EngineInputTests {
    @Test func handsOutDroppedFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "rhino-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let notes = folder.appending(path: "notes.txt")
        let people = folder.appending(path: "people.CSV")
        try Data("hello".utf8).write(to: notes)
        try Data("name;city\n\"Ada, Countess\";London\nLinus;\"Hel\"\"sinki\"\n".utf8).write(to: people)

        let (engine, _) = makeEngine(["m": """
        const table = await input.file({ ext: "csv" });
        const first = await input.file();
        output.json({
          table: table.name,
          ext: table.ext,
          rows: await table.csv(),
          first: first.name,
          text: await first.text(),
          all: input.files.map((f) => f.name),
        });
        """])
        let summary = await engine.run("m", files: [notes, people])

        #expect(summary.error == nil)
        let result = try #require(try json(summary.resultJSON) as? [String: Any])
        #expect(result["table"] as? String == "people.CSV")
        #expect(result["ext"] as? String == "csv")
        #expect(result["rows"] as? [[String: String]] == [
            ["name": "Ada, Countess", "city": "London"],
            ["name": "Linus", "city": "Hel\"sinki"],
        ])
        #expect(result["first"] as? String == "notes.txt")
        #expect(result["text"] as? String == "hello")
        #expect(result["all"] as? [String] == ["notes.txt", "people.CSV"])
    }

    @Test func asksForAFileWhenNoneWasDropped() async throws {
        let picked = FileManager.default.temporaryDirectory.appending(path: "rhino-\(UUID().uuidString).json")
        try Data(#"{"n":7}"#.utf8).write(to: picked)
        defer { try? FileManager.default.removeItem(at: picked) }

        let (engine, _) = makeEngine(["m": """
        const file = await input.file("Pick the config", { ext: ["json", ".yaml"] });
        output.json(await file.json());
        """])
        let recorder = Recorder { _ in .file(picked) }
        let summary = await engine.run("m", interactive: true, events: recorder.record)

        #expect(try json(summary.resultJSON) as? [String: Int] == ["n": 7])
        let prompt = try #require(recorder.events.compactMap { if case .prompt(let request) = $0 { request } else { nil } }.first)
        #expect(prompt.kind == .file)
        #expect(prompt.message == "Pick the config")
        #expect(prompt.options == ["json", "yaml"])

        // Nobody to ask on an unattended run.
        #expect(await engine.run("m").error?.message.contains("unattended") == true)
    }

    @Test func askReturnsTypedAnswers() async throws {
        let (engine, _) = makeEngine(["m": """
        const name = await input.ask("Name?");
        const count = await input.ask("How many?", { type: "number" });
        const env = await input.ask("Where?", { options: ["staging", "prod"] });
        const sure = await input.confirm("Sure?");
        output.json({ name, count, env, sure });
        """])
        let recorder = Recorder { request in
            switch request.kind {
            case .number: .number(3)
            case .confirm: .bool(true)
            case .choice: .text(request.options.last ?? "")
            default: .text("Ada")
            }
        }
        let summary = await engine.run("m", interactive: true, events: recorder.record)

        #expect(summary.error == nil)
        let result = try #require(try json(summary.resultJSON) as? [String: Any])
        #expect(result["name"] as? String == "Ada")
        #expect(result["count"] as? Int == 3)
        #expect(result["env"] as? String == "prod")
        #expect(result["sure"] as? Bool == true)
    }

    @Test func askWithoutAnAudience() async throws {
        let (engine, _) = makeEngine([
            "withDefault": #"output.json(await input.ask("Name?", { default: "world" }));"#,
            "noDefault": #"output.json(await input.ask("Name?"));"#,
        ])
        #expect(await engine.run("withDefault").resultJSON == "\"world\"")
        #expect(await engine.run("noDefault").error?.message.contains("unattended") == true)
        #expect(await engine.run("noDefault", interactive: true, events: Recorder().record).error?.message.contains("Cancelled") == true)
    }
}
