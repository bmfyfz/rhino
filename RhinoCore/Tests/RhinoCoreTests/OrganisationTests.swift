import Foundation
import Testing
@testable import RhinoCore

/// Folders of scripts, moving scripts between them, and searching.
@Suite struct OrganisationTests {
    private func makeStore() throws -> ScriptStore {
        let store = ScriptStore(directory: FileManager.default.temporaryDirectory.appending(path: "rhino-store-\(UUID().uuidString)"))
        try store.save("// @name Fetch users\n// @description Pulls the user list\noutput.log('top');\n", to: "fetch-users")
        try store.save("// @name Monthly report\nconst total = 42;\noutput.json(total);\n", to: "reports/monthly")
        try store.save("output.log('no header');\n", to: "reports/2026/q1")
        return store
    }

    @Test func findsScriptsInFolders() throws {
        let store = try makeStore()
        try store.createFolder("empty")
        // Not scripts, and not folders anyone made: none of this shows up.
        try FileManager.default.createDirectory(at: store.directory.appending(path: ".git/hooks"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: store.directory.appending(path: ".git/hooks/sample.js"))
        try Data("x".utf8).write(to: store.directory.appending(path: "reports/notes.txt"))

        let scripts = store.scripts()
        #expect(scripts.map(\.id).sorted() == ["fetch-users", "reports/2026/q1", "reports/monthly"])
        #expect(Dictionary(uniqueKeysWithValues: scripts.map { ($0.id, $0.folder) }) == ["fetch-users": "", "reports/monthly": "reports", "reports/2026/q1": "reports/2026"])
        // Without a header a script is called by its file name, not its whole path.
        #expect(scripts.first { $0.id == "reports/2026/q1" }?.name == "q1")
        #expect(store.folders() == ["empty", "reports", "reports/2026"])
        #expect(try store.source(of: "reports/monthly").contains("const total = 42"))
    }

    @Test func runFindsAScriptByPathTitleOrFileName() throws {
        let store = try makeStore()
        #expect(store.script(named: "reports/monthly")?.id == "reports/monthly")
        #expect(store.script(named: "Monthly report")?.id == "reports/monthly")
        #expect(store.script(named: "monthly")?.id == "reports/monthly")
        #expect(store.script(named: "q1.js")?.id == "reports/2026/q1")
        #expect(store.script(named: "nothing") == nil)

        // A file name two scripts share says nothing; the path still does.
        try store.save("// @name Last year\noutput.log(1);", to: "archive/monthly")
        #expect(store.script(named: "monthly") == nil)
        #expect(store.script(named: "archive/monthly")?.id == "archive/monthly")
    }

    @Test func createsAndMovesScripts() throws {
        let store = try makeStore()
        let made = try store.create(named: "Monthly", in: "reports")
        #expect(made.id == "reports/monthly-2")
        #expect(made.name == "Monthly")
        #expect(try store.create(named: "New thing", in: " drafts / week 1 ").id == "drafts/week 1/new-thing")

        #expect(try store.move("fetch-users", to: "reports") == "reports/fetch-users")
        #expect(try store.move("reports/fetch-users", to: "reports") == "reports/fetch-users")
        #expect(try store.move("reports/2026/q1", to: "") == "q1")
        // Something of that name is already there, so the newcomer gets a number.
        try store.save("output.log(2);", to: "monthly")
        #expect(try store.move("monthly", to: "reports") == "reports/monthly-3")
        #expect(Set(store.scripts().map(\.id)) == ["reports/fetch-users", "q1", "reports/monthly", "reports/monthly-2", "reports/monthly-3", "drafts/week 1/new-thing"])
    }

    @Test func renamesAndDeletesFolders() throws {
        let store = try makeStore()
        let moved = try store.renameFolder("reports", to: "Numbers")
        #expect(moved == ["reports/monthly": "Numbers/monthly", "reports/2026/q1": "Numbers/2026/q1"])
        #expect(store.folders() == ["Numbers", "Numbers/2026"])
        #expect(try store.renameFolder("Numbers/2026", to: "last year") == ["Numbers/2026/q1": "Numbers/last year/q1"])

        try store.createFolder("taken")
        #expect(throws: ScriptStore.Problem.self) { try store.renameFolder("Numbers", to: "taken") }
        #expect(throws: ScriptStore.Problem.self) { try store.renameFolder("Numbers", to: "a/b") }
        // A folder with scripts anywhere inside is not thrown away with them.
        #expect(throws: ScriptStore.Problem.self) { try store.deleteFolder("Numbers") }
        try store.deleteFolder("taken")
        #expect(store.folders() == ["Numbers", "Numbers/last year"])
    }

    @Test func refusesFolderNamesThatLeadElsewhere() throws {
        #expect(try ScriptStore.folderPath("  reports // 2026 /") == "reports/2026")
        #expect(try ScriptStore.folderPath("") == "")
        for bad in ["..", "a/../b", ".hidden", "a:b", "/etc/../x"] {
            #expect(throws: ScriptStore.Problem.self, "\(bad)") { try ScriptStore.folderPath(bad) }
        }
        let store = try makeStore()
        #expect(throws: ScriptStore.Problem.self) { try store.move("fetch-users", to: "../outside") }
        #expect(throws: ScriptStore.Problem.self) { try store.createFolder("  ") }
    }

    @Test func aMovedScriptKeepsItsVersionsAndMemory() throws {
        let versions = ScriptVersions(directory: FileManager.default.temporaryDirectory.appending(path: "rhino-versions-\(UUID().uuidString)"))
        try versions.record("one", of: "fetch-users", reason: .edit)
        versions.rename("fetch-users", to: "reports/fetch-users")
        #expect(versions.versions(of: "reports/fetch-users").map(\.source) == ["one"])
        #expect(versions.versions(of: "fetch-users").isEmpty)

        let memory = FileMemoryStore(directory: FileManager.default.temporaryDirectory.appending(path: "rhino-memory-\(UUID().uuidString)"))
        try memory.set(json: "7", forKey: "count", script: "fetch-users")
        memory.rename(script: "fetch-users", to: "reports/fetch-users")
        #expect(memory.json(forKey: "count", script: "reports/fetch-users") == "7")
        #expect(memory.keys(script: "fetch-users").isEmpty)
        // Nothing to carry over is not an error.
        memory.rename(script: "never-there", to: "x")
    }

    @Test func searchesNamesDescriptionsAndCode() throws {
        let store = try makeStore()
        try store.save("// @name Café orders\n// @description Totals per café\nconst users = await get(url);\nconst more = users.length;\nusers.sort();\nusers.reverse();\n", to: "cafe")
        let all = store.scripts().map { (script: $0, source: (try? store.source(of: $0.id)) ?? "") }
        func found(_ query: String) -> [String] {
            ScriptSearch.matches(for: query, in: all).map { match in
                switch match.place {
                case .name: "\(match.scriptID) name"
                case .description: "\(match.scriptID) description"
                case .code(let line): "\(match.scriptID):\(line) \(match.text)"
                }
            }
        }

        // Names first, then descriptions, then the lines of code, a few per script.
        #expect(found("users") == [
            "fetch-users name",
            "cafe:3 const users = await get(url);", "cafe:4 const more = users.length;", "cafe:5 users.sort();",
        ])
        #expect(found("user list") == ["fetch-users description"])
        // Case and accents do not matter, and a file name counts as a name.
        #expect(found("CAFE") == ["cafe name"])
        #expect(found("q1") == ["reports/2026/q1 name"])
        #expect(found("TOTAL") == ["cafe description", "reports/monthly:2 const total = 42;", "reports/monthly:3 output.json(total);"])
        #expect(found("   ").isEmpty)
        #expect(found("zebra").isEmpty)
    }
}
