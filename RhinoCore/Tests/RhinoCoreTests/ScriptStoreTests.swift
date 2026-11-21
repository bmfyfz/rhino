import Foundation
import Testing
@testable import RhinoCore

/// `ScriptStore` and `ScriptHeader`: headers and shortcuts, scripts as files, and the seeded examples.
@Suite struct ScriptStoreTests {
    @Test func parsesHeaderAndShortcut() {
        let header = ScriptHeader.parse("""
        // @name  Fetch users
        //   @key cmd+shift+u

        // @schedule every 15m
        const x = 1;
        // @description too late
        """)
        #expect(header == ["name": "Fetch users", "key": "cmd+shift+u", "schedule": "every 15m"])

        let shortcut = Shortcut("cmd+shift+u")
        #expect(shortcut?.key == "u")
        #expect(shortcut?.modifiers == [.command, .shift])
        #expect(shortcut?.symbols == "⇧⌘U")
        #expect(Shortcut("shift+u") == nil)
        #expect(Shortcut("cmd+enter") == nil)
    }

    @Test func storesScriptsAsFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "rhino-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScriptStore(directory: directory)

        try store.seedExamplesIfNeeded()
        #expect(store.scripts().map(\.id).sorted() == [
            "AI/sort-feedback", "AI/summarise-stories", "Pipelines/compare-repositories", "Pipelines/news-digest",
            "csv-report", "currency-rates", "earthquakes", "github-repository", "hacker-news", "mac-status",
            "picture-of-the-day", "site-check", "weather-outlook",
        ])
        try store.save("// @name Repo Stats\n// @key cmd+shift+g\noutput.json(1);\n", to: "repo-stats")
        #expect(store.scripts().first { $0.id == "repo-stats" }?.shortcut?.symbols == "⇧⌘G")

        let created = try store.create(named: "My New Thing!")
        #expect(created.id == "my-new-thing")
        #expect(created.name == "My New Thing!")
        #expect(try store.create(named: "My New Thing!").id == "my-new-thing-2")

        // Resolves by id, by file name and by display name.
        #expect(store.script(named: "repo-stats")?.id == "repo-stats")
        #expect(store.script(named: "repo-stats.js")?.id == "repo-stats")
        #expect(store.script(named: "Repo Stats")?.id == "repo-stats")
        #expect(store.script(named: "nope") == nil)
    }

    /// The seeded examples and the starter template must be sound: each
    /// parses against the API people and the AI are told about, says what it
    /// is, and the ones that need no network run as written.
    @Test func examplesAndTemplateRun() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "rhino-examples-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScriptStore(directory: directory.appending(path: "Scripts"))
        try store.seedExamplesIfNeeded()
        let template = try store.create(named: "Fresh")

        for script in store.scripts() where script.id != template.id {
            let source = try store.source(of: script.id)
            #expect(ScriptCompiler.syntaxProblem(in: source) == nil, "\(script.id)")
            #expect(ScriptHeader.parse(source)["name"]?.isEmpty == false, "\(script.id) has no @name")
            #expect(script.summary?.isEmpty == false, "\(script.id) has no @description")
            // An example must not start doing things by itself on a new installation.
            #expect(script.schedule == nil && script.watch == nil, "\(script.id) would run by itself")
        }

        // The one example that needs only a file.
        let table = directory.appending(path: "sales.csv")
        try Data("month,total\nJan,10\nFeb,14\n".utf8).write(to: table)
        let engine = Engine(provider: store, runsDirectory: directory.appending(path: "Runs"))
        let recorder = Recorder()
        let report = await engine.run("csv-report", files: [table], events: recorder.record)
        #expect(report.error == nil)
        #expect(recorder.outputs.map(\.kind) == [.table, .chart, .json])
        #expect(recorder.outputs.map(\.name) == ["sales.csv", "total by month", "Summary"])
        #expect(recorder.savedFiles.map(\.name) == ["As JSON"])
        let saved = try String(contentsOf: try #require(recorder.savedFiles.first).url, encoding: .utf8)
        #expect(try json(saved) as? [[String: String]] == [["month": "Jan", "total": "10"], ["month": "Feb", "total": "14"]])

        #expect(try json(await engine.run(template.id).resultJSON) as? [String: Bool] == ["ok": true])

        // What the examples reach for is what their descriptions say.
        func footprint(_ id: String) throws -> Set<ScriptFootprint.Item> { ScriptFootprint(of: try store.source(of: id)).items }
        #expect(try footprint("csv-report").isEmpty)
        #expect(try footprint("weather-outlook") == [.host("geocoding-api.open-meteo.com"), .host("api.open-meteo.com")])
        #expect(try footprint("mac-status").allSatisfy { if case .command = $0 { true } else { false } })
        #expect(try footprint("Pipelines/news-digest") == [.runs("Hacker News top stories"), .runs("Summarise stories")])
        #expect(try footprint("AI/sort-feedback") == [.ai])
    }
}
