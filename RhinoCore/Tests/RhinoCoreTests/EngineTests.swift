import Foundation
import Testing
@testable import RhinoCore

/// Running a script: results, logs, chained runs, HTTP calls, errors with their line, and cancellation.
@Suite struct EngineTests {
    @Test func returnsResultAndLogs() async throws {
        let (engine, _) = makeEngine(["hello": """
        output.log("files:", input.files.length);
        output.warn({ a: 1 });
        console.log("data is", input.data);
        output.json({ sum: 1 + 2 });
        """])
        let recorder = Recorder()
        let summary = await engine.run("hello", events: recorder.record)

        #expect(summary.error == nil)
        #expect(try json(summary.resultJSON) as? [String: Int] == ["sum": 3])
        #expect(recorder.logs[0] == "files: 0")
        #expect(recorder.logs[1].contains("\"a\": 1"))
        #expect(recorder.logs[2] == "data is null")
    }

    @Test func resultIsOptionalAndLastOneWins() async throws {
        let (engine, _) = makeEngine([
            "silent": #"output.log("no result");"#,
            "twice": "output.json(1);\noutput.json(2);",
            "early": "if (input.files.length === 0) return;\noutput.json('not reached');",
            "returned": "return { via: 'return' };",
        ])
        #expect(await engine.run("silent").resultJSON == nil)
        #expect(await engine.run("silent").error == nil)
        #expect(await engine.run("twice").resultJSON == "2")
        #expect(await engine.run("early").resultJSON == nil)
        #expect(try json(await engine.run("returned").resultJSON) as? [String: String] == ["via": "return"])
    }

    @Test func chainsScriptsAndAttributesLogs() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "rhino-\(UUID().uuidString).txt")
        try Data("shared".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let (engine, _) = makeEngine([
            "parent": """
            const [a, b] = await Promise.all([run("double", { n: 2 }), run("double", { n: 5 })]);
            output.log("parent done");
            output.json({ sum: a.value + b.value, seen: a.file });
            """,
            "double": """
            await sleep(input.data.n);
            output.log("doubling", input.data.n);
            const file = await input.file();
            output.json({ value: input.data.n * 2, file: await file.text() });
            """,
        ])
        let recorder = Recorder()
        let summary = await engine.run("parent", files: [file], events: recorder.record)

        // Children see the files dropped on the run and return what they gave output.json().
        let result = try #require(try json(summary.resultJSON) as? [String: Any])
        #expect(result["sum"] as? Int == 14)
        #expect(result["seen"] as? String == "shared")

        let root = try #require(recorder.runs.first { $0.parentID == nil })
        let children = recorder.runs.filter { $0.parentID == root.id }
        #expect(root.script == "parent")
        #expect(children.map(\.script) == ["double", "double"])

        // Each log line belongs to the run that wrote it, even though both children overlap.
        let owners = recorder.events.compactMap { event -> String? in
            guard case .log(let entry) = event, entry.message.hasPrefix("doubling") else { return nil }
            return entry.runID
        }
        #expect(Set(owners) == Set(children.map(\.id)))
    }

    @Test func recordsHTTPSpans() async throws {
        let (engine, _) = makeEngine(["m": """
        const users = await get("https://api.test/users");
        const echo = await post("https://api.test/echo", { hi: 1 }, { query: { page: 2, tag: ["a", "b"] } });
        const text = await http.delete("https://api.test/text");
        output.json({ names: users.data.map((u) => u.name), echo: echo.data, text: text.data, ok: users.ok });
        """])
        let recorder = Recorder()
        let summary = await engine.run("m", events: recorder.record)

        #expect(summary.error == nil)
        let result = try #require(try json(summary.resultJSON) as? [String: Any])
        #expect(result["names"] as? [String] == ["Ada", "Linus"])
        #expect(result["text"] as? String == "plain words")
        let echo = try #require(result["echo"] as? [String: String])
        #expect(echo["method"] == "POST")
        #expect(echo["query"] == "page=2&tag=a&tag=b")
        #expect(echo["contentType"] == "application/json")
        #expect(echo["body"] == #"{"hi":1}"#)

        let spans = recorder.finishedSpans
        #expect(spans.map(\.method) == ["GET", "POST", "DELETE"])
        #expect(spans.allSatisfy { $0.status == 200 && $0.duration != nil })
        #expect(spans[1].requestBody == #"{"hi":1}"#)
        #expect(spans[0].responseBody?.contains("Ada") == true)
    }

    @Test func httpErrorFailsRunWithScriptLine() async throws {
        let (engine, _) = makeEngine(["m": """
        output.log("before");
        await get("https://api.test/missing");
        output.log("after");
        """])
        let recorder = Recorder()
        let summary = await engine.run("m", events: recorder.record)

        let error = try #require(summary.error)
        #expect(error.message.contains("status 500"))
        #expect(error.script == "m")
        #expect(error.line == 2)
        #expect(recorder.logs == ["before"])
        #expect(recorder.finishedSpans.first?.status == 500)
    }

    @Test func httpErrorCanBeInspected() async throws {
        let (engine, _) = makeEngine(["m": """
        const res = await get("https://api.test/missing", { throwOnError: false });
        output.json({ status: res.status, ok: res.ok, error: res.data.error });
        """])
        let summary = await engine.run("m")
        let result = try #require(try json(summary.resultJSON) as? [String: Any])
        #expect(result["status"] as? Int == 500)
        #expect(result["ok"] as? Bool == false)
        #expect(result["error"] as? String == "boom")
    }

    @Test func thrownErrorReportsLine() async throws {
        let (engine, _) = makeEngine(["m": """
        // @name Thrower

        const value = null;
        output.json(value.missing);
        """])
        let error = try #require(await engine.run("m").error)
        #expect(error.name == "TypeError")
        #expect(error.script == "m")
        #expect(error.line == 4)
    }

    @Test func syntaxErrorIsReported() async throws {
        let (engine, _) = makeEngine(["m": "const a = 1;\nconst b = {;\n"])
        let error = try #require(await engine.run("m").error)
        #expect(error.name == "SyntaxError")
        #expect(error.script == "m")
        #expect(error.line == 2)
    }

    @Test func unsupportedSyntaxAndMissingScriptsAreExplained() async throws {
        let (engine, _) = makeEngine([
            "caller": #"output.json(await run("nope"));"#,
            "importer": "import fs from 'fs';\noutput.log(fs);",
            "exporter": "const a = 1;\nexport default async function main() {}",
        ])
        #expect(await engine.run("ghost").error?.message.contains("Script not found") == true)
        #expect(await engine.run("caller").error?.message.contains("nope") == true)
        #expect(await engine.run("importer").error?.message.contains("Line 1: `import` is not supported") == true)
        #expect(await engine.run("exporter").error?.message.contains("Line 2: `export` is not needed") == true)
    }

    @Test func cancellationStopsARun() async throws {
        let (engine, _) = makeEngine(["m": """
        output.log("started");
        await sleep(60000);
        output.log("never");
        """])
        let recorder = Recorder()
        let task = Task { await engine.run("m", events: recorder.record) }
        while recorder.logs.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()

        let summary = await task.value
        #expect(summary.error?.message == "Run cancelled")
        #expect(recorder.logs == ["started"])
        #expect(summary.duration < 5)
    }
}
