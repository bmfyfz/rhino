import Foundation
import Testing
@testable import RhinoCore

/// `secrets` and `memory`: asking for a secret once, keeping it out of logs and records, and per-script memory between runs.
@Suite struct SecretsAndMemoryTests {
    private func makeEngine(_ sources: [String: String], secrets: any SecretStore = InMemorySecretStore(), memory: any MemoryStore = InMemoryMemoryStore()) -> Engine {
        let runs = FileManager.default.temporaryDirectory.appending(path: "rhino-tests-\(UUID().uuidString)")
        return Engine(provider: Scripts(sources: sources), runsDirectory: runs, session: stubbedSession(), secrets: secrets, memory: memory)
    }

    static let tokenScript = """
    const token = await secrets.get("API_TOKEN", "The token for the test API");
    output.log("The token is", token);
    const res = await post("https://api.test/echo", { key: token }, { headers: { Authorization: `Bearer ${token}` } });
    output.json({ length: token.length, sent: res.data.body.includes(token) });
    """

    @Test func asksForASecretOnceAndKeepsItOutOfTheRecord() async throws {
        let secrets = InMemorySecretStore()
        let engine = makeEngine(["m": Self.tokenScript], secrets: secrets)

        // First run: the user is asked, and what they type is saved.
        let first = Recorder { request in request.kind == .secret ? .text("s3cr3t-value") : .cancelled }
        let summary = await engine.run("m", interactive: true, events: first.record)
        #expect(summary.error == nil)
        let prompt = try #require(first.events.compactMap { if case .prompt(let request) = $0 { request } else { nil } }.first)
        #expect(prompt.kind == .secret)
        #expect(prompt.secretName == "API_TOKEN")
        #expect(prompt.message == "The token for the test API")
        #expect(secrets.value(named: "API_TOKEN") == "s3cr3t-value")

        // The script got the real value and really sent it…
        #expect(try json(summary.resultJSON) as? NSDictionary == ["length": 12, "sent": true])
        // …but the log and the recorded call show none of it.
        #expect(first.logs == ["The token is ••••••"])
        let span = try #require(first.finishedSpans.first)
        // A header that carries credentials is blanked whole, not just the part known to be secret.
        #expect(span.requestHeaders["Authorization"] == "••••••")
        #expect(span.requestBody == #"{"key":"••••••"}"#)
        #expect(span.responseBody?.contains("s3cr3t-value") == false)

        // Later runs, unattended ones too, are not asked again.
        let second = Recorder()
        let again = await engine.run("m", events: second.record)
        #expect(again.error == nil)
        #expect(second.events.contains { if case .prompt = $0 { true } else { false } } == false)
        #expect(second.logs == ["The token is ••••••"])
    }

    @Test func aMissingSecretFailsClearly() async {
        let engine = makeEngine(["m": Self.tokenScript, "unnamed": "await secrets.get();"])

        let unattended = await engine.run("m").error?.message
        #expect(unattended?.contains("“API_TOKEN” is not saved yet") == true)

        let dismissed = await engine.run("m", interactive: true, events: Recorder().record).error?.message
        #expect(dismissed?.contains("Cancelled") == true)

        let empty = await engine.run("m", interactive: true, events: Recorder { _ in .text("") }.record).error?.message
        #expect(empty?.contains("Nothing was entered") == true)

        #expect(await engine.run("unnamed").error?.message.contains("needs the name") == true)
    }

    @Test func remembersBetweenRunsPerScript() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "rhino-memory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = FileMemoryStore(directory: directory)
        let counter = """
        const runs = (await memory.get("runs", 0)) + 1;
        await memory.set("runs", runs);
        await memory.set("seen", { ids: [1, runs], note: "ünïcode" });
        output.json({ runs, missing: await memory.get("nothing"), keys: await memory.keys() });
        """
        let engine = makeEngine([
            "counter": counter,
            "other one": #"output.json({ runs: await memory.get("runs", "none"), viaChild: (await run("counter")).runs });"#,
            "forgetful": """
            await memory.set("temp", 1);
            await memory.delete("temp");
            await memory.set("kept", undefined);
            output.json({ keys: await memory.keys(), kept: await memory.get("kept", "fallback") });
            """,
        ], memory: memory)

        let first = try #require(try json(await engine.run("counter").resultJSON) as? [String: Any])
        #expect(first["runs"] as? Int == 1)
        #expect(first["missing"] is NSNull)
        #expect(first["keys"] as? [String] == ["runs", "seen"])
        #expect((try json(await engine.run("counter").resultJSON) as? [String: Any])?["runs"] as? Int == 2)

        // Another script has its own memory; a script it runs keeps its own too.
        let other = try #require(try json(await engine.run("other one").resultJSON) as? [String: Any])
        #expect(other["runs"] as? String == "none")
        #expect(other["viaChild"] as? Int == 3)

        // It survives a new store on the same folder, as it does a relaunch.
        let reopened = FileMemoryStore(directory: directory)
        #expect(reopened.json(forKey: "runs", script: "counter") == "3")
        #expect(try json(reopened.json(forKey: "seen", script: "counter")) as? NSDictionary == ["ids": [1, 3], "note": "ünïcode"])
        #expect(reopened.keys(script: "other one").isEmpty)

        let forgetful = try #require(try json(await engine.run("forgetful").resultJSON) as? [String: Any])
        #expect(forgetful["keys"] as? [String] == ["kept"])
        // A stored null is a value, so the fallback is not used.
        #expect(forgetful["kept"] is NSNull)

        try reopened.clear(script: "counter")
        #expect(reopened.keys(script: "counter").isEmpty)
        #expect((try json(await engine.run("counter").resultJSON) as? [String: Any])?["runs"] as? Int == 1)
    }
}
