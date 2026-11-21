import Foundation
import Testing
@testable import RhinoCore

/// What a script publishes through `output` (named values, images, charts, tables, text) and the files it writes and reads back.
@Suite struct EngineOutputTests {
    @Test func publishesNamedOutputs() async throws {
        let (engine, _) = makeEngine([
            "m": """
            output.json({ users: 2 }).name("Active users").name("  Users, final name  ");
            output.log("between");
            output.json([1, 2]);
            const inner = await run("child");
            output.json({ inner }).name("");
            """,
            "child": #"output.json("from child").name("Never shown");"#,
        ])
        let recorder = Recorder()
        let summary = await engine.run("m", events: recorder.record)
        #expect(summary.error == nil)

        // Only the script that was run publishes; the child's value is its return value.
        let outputs = recorder.outputs
        #expect(outputs.map(\.name) == ["Users, final name", nil, nil])
        #expect(try json(outputs[0].json) as? [String: Int] == ["users": 2])
        #expect(try json(outputs[1].json) as? [Int] == [1, 2])
        #expect(try json(outputs[2].json) as? [String: String] == ["inner": "from child"])

        // The value is published where the script wrote it, not at the end.
        let kinds = recorder.events.compactMap { event -> String? in
            switch event {
            case .output(let value): "output:\(value.name ?? "-")"
            case .log: "log"
            default: nil
            }
        }
        #expect(kinds.prefix(4) == ["output:-", "output:Active users", "output:Users, final name", "log"])

        // The last published value is still the script's result.
        #expect(try json(summary.resultJSON) as? [String: String] == ["inner": "from child"])
    }

    @Test func publishesPicturesChartsTablesAndNotes() async throws {
        let (engine, _) = makeEngine(["m": """
        output.image("https://example.com/a.png").name("Remote");
        output.image("pics/local.png");
        output.image("  <svg xmlns='http://www.w3.org/2000/svg' width='10' height='10'></svg>");
        output.image("data:image/png;base64,aGVsbG8=");

        output.chart(
          [{ month: "Jan", revenue: 10, cost: "4" }, { month: "Feb", revenue: 12, cost: "5" }],
          { type: "line", title: "Money" }
        ).name("Revenue and cost");
        output.chart([3, 1, 2]);
        output.chart([["2026-01-01", 5], ["2026-01-02", 7]], { type: "area" });
        output.chart(
          [{ city: "A", n: 1, year: "2025" }, { city: "A", n: 2, year: "2026" }],
          { x: "city", y: "n", series: "year", type: "column" }
        );

        output.table([{ name: "Ada", age: 36, tags: ["x"] }, { name: "Linus", age: null }]).name("People");
        output.text("**Done** in 3 steps");
        output.json({ ok: true });
        """])
        let recorder = Recorder()
        let summary = await engine.run("m", events: recorder.record)
        #expect(summary.error == nil)

        let outputs = recorder.outputs
        #expect(outputs.map(\.kind) == [.image, .image, .image, .image, .chart, .chart, .chart, .chart, .table, .text, .json])
        #expect(outputs[0].name == "Remote")
        #expect(outputs[8].name == "People")

        // Images: where each one comes from.
        #expect(ImageSource(json: outputs[0].json) == .remote(URL(string: "https://example.com/a.png")!))
        #expect(ImageSource(json: outputs[1].json) == .file(summary.outputDirectory.appending(path: "pics/local.png")))
        guard case .data(let svg)? = ImageSource(json: outputs[2].json) else {
            Issue.record("the SVG should arrive as data")
            return
        }
        #expect(String(decoding: svg, as: UTF8.self).hasPrefix("<svg"))
        #expect(ImageSource(json: outputs[3].json) == .data(Data("hello".utf8)))

        // Charts: columns are found without being named, and text numbers count.
        let money = try #require(ChartData(json: outputs[4].json))
        #expect(money.kind == .line)
        #expect(money.title == "Money")
        #expect(money.axis == .categories)
        #expect(money.xLabel == "month")
        #expect(money.series == ["revenue", "cost"])
        #expect(money.points.map(\.label) == ["Jan", "Jan", "Feb", "Feb"])
        #expect(money.points.map(\.y) == [10, 4, 12, 5])

        let plain = try #require(ChartData(json: outputs[5].json))
        #expect(plain.kind == .bar)
        #expect(plain.axis == .numbers)
        #expect(plain.points.map(\.number) == [1, 2, 3])
        #expect(plain.points.map(\.y) == [3, 1, 2])
        #expect(plain.series.isEmpty)

        let dated = try #require(ChartData(json: outputs[6].json))
        #expect(dated.kind == .area)
        #expect(dated.axis == .dates)
        #expect(dated.points[1].date.timeIntervalSince(dated.points[0].date) == 86400)

        let split = try #require(ChartData(json: outputs[7].json))
        #expect(split.kind == .bar)
        #expect(split.xLabel == "city")
        #expect(split.yLabel == "n")
        #expect(split.series == ["2025", "2026"])

        // Tables: cells are text, and number columns are marked.
        let people = try #require(TableData(json: outputs[8].json))
        #expect(people.columns == ["name", "age", "tags"])
        #expect(people.rows == [["Ada", "36", "[\"x\"]"], ["Linus", "", ""]])
        #expect(people.numericColumns == [1])
        #expect(people.totalRows == 2)

        #expect(outputs[9].text == "**Done** in 3 steps")
        // Only output.json() is the script's result.
        #expect(try json(summary.resultJSON) as? [String: Bool] == ["ok": true])
    }

    @Test func explainsOutputsItCannotShow() async {
        let (engine, _) = makeEngine([
            "empty": "output.chart([]);",
            "words": #"output.chart([{ a: "x", b: "y" }]);"#,
            "radar": #"output.chart([1, 2], { type: "radar" });"#,
            "number": "output.log('before');\noutput.image(42);",
        ])
        #expect(await engine.run("empty").error?.message.contains("at least one row") == true)
        #expect(await engine.run("words").error?.message.contains("no numeric column") == true)
        #expect(await engine.run("radar").error?.message.contains(#"unknown type "radar""#) == true)
        let number = await engine.run("number").error
        #expect(number?.message.contains("output.image() takes") == true)
        #expect(number?.line == 2)
    }

    @Test func writesOutputFiles() async throws {
        let (engine, runs) = makeEngine(["m": """
        const file = "shadows the global, which is fine";
        const path = await output.file("out/data.json", { a: [1, 2] });
        const back = JSON.parse(await read("out/data.json"));
        output.json({ path, back });
        """])
        defer { try? FileManager.default.removeItem(at: runs) }
        let recorder = Recorder()
        let summary = await engine.run("m", events: recorder.record)

        #expect(summary.error == nil)
        let result = try #require(try json(summary.resultJSON) as? [String: Any])
        let path = try #require(result["path"] as? String)
        #expect(path.hasPrefix(summary.outputDirectory.path(percentEncoded: false)))
        #expect((result["back"] as? [String: [Int]]) == ["a": [1, 2]])
        #expect(recorder.writtenFiles.map(\.lastPathComponent) == ["data.json"])
    }

    @Test func namesSavedFiles() async throws {
        let (engine, runs) = makeEngine(["m": """
        const path = await output.file("export.csv", "a,b").name("Orders in March");
        await output.file("plain.txt", "x");
        await write("scratch.txt", "y");
        output.json({ isPath: path.endsWith("/export.csv"), noNameOnWrite: write("again.txt", "z").name === undefined });
        """])
        defer { try? FileManager.default.removeItem(at: runs) }
        let recorder = Recorder()
        let summary = await engine.run("m", events: recorder.record)

        #expect(summary.error == nil)
        // Awaiting still gives the path; only output.file() can be named.
        #expect(try json(summary.resultJSON) as? [String: Bool] == ["isPath": true, "noNameOnWrite": true])
        let files = recorder.savedFiles
        #expect(files.map(\.url.lastPathComponent) == ["export.csv", "plain.txt", "scratch.txt", "again.txt"])
        #expect(files.map(\.name) == ["Orders in March", nil, nil, nil])
    }

    @Test func readsAndListsTheFilesystem() async throws {
        let (engine, runs) = makeEngine(["m": """
        await write("out/a.txt", "A");
        output.json({ exists: await file.exists("out/a.txt"), missing: await file.exists("nope"), listed: await file.list("out") });
        """])
        defer { try? FileManager.default.removeItem(at: runs) }
        let result = try #require(try json(await engine.run("m").resultJSON) as? [String: Any])
        #expect(result["exists"] as? Bool == true)
        #expect(result["missing"] as? Bool == false)
        #expect(result["listed"] as? [String] == ["a.txt"])
    }
}
