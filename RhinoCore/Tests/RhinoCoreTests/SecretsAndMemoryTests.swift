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

/// Which script may read which saved secret: the one that asked for it, and
/// any other only after the user said so.
@Suite struct SecretGrantTests {
    private static let reader = """
    // @name Reader
    output.json({ token: (await secrets.get("API_TOKEN")).length });
    """
    private static let owner = """
    // @name Owner
    await secrets.get("API_TOKEN", "The token for the test API");
    """

    private func makeEngine(_ sources: [String: String], secrets: any SecretStore, grants: any SecretGrants) -> Engine {
        let runs = FileManager.default.temporaryDirectory.appending(path: "rhino-tests-\(UUID().uuidString)")
        return Engine(provider: Scripts(sources: sources), runsDirectory: runs, session: stubbedSession(), secrets: secrets, grants: grants)
    }

    private func prompts(_ recorder: Recorder) -> [PromptRequest] {
        recorder.events.compactMap { if case .prompt(let request) = $0 { request } else { nil } }
    }

    @Test func theScriptThatAskedForASecretKeepsIt() async {
        let secrets = InMemorySecretStore()
        let grants = InMemorySecretGrants()
        let engine = makeEngine(["owner": Self.owner], secrets: secrets, grants: grants)

        let first = Recorder { _ in .text("s3cr3t-value") }
        #expect(await engine.run("owner", interactive: true, events: first.record).error == nil)
        #expect(prompts(first).map(\.kind) == [.secret])
        #expect(grants.allows(script: "owner", secret: "API_TOKEN"))

        // From then on it reads the secret without a question, unattended too.
        let later = Recorder()
        #expect(await engine.run("owner", events: later.record).error == nil)
        #expect(prompts(later).isEmpty)
    }

    @Test func anotherScriptHasToBeAllowedFirst() async throws {
        let grants = InMemorySecretGrants(["API_TOKEN": ["owner"]])
        let engine = makeEngine(
            ["owner": Self.owner, "reader": Self.reader],
            secrets: InMemorySecretStore(["API_TOKEN": "s3cr3t-value"]), grants: grants
        )

        // With nobody to ask, it does not get the secret.
        let unattended = await engine.run("reader").error?.message
        #expect(unattended == "“Reader” has not been allowed to use the saved secret “API_TOKEN”. Run it once by hand to be asked.")

        // The user is asked, by the script's name, and the answer on offer is no.
        let refused = Recorder { _ in .bool(false) }
        let denied = await engine.run("reader", interactive: true, events: refused.record)
        let question = try #require(prompts(refused).first)
        #expect(question.kind == .confirm)
        #expect(question.secretName == "API_TOKEN")
        #expect(question.message == "Allow “Reader” to use your saved secret “API_TOKEN”?")
        #expect(question.defaultText == "false")
        #expect(denied.error?.message.contains("did not allow") == true)
        #expect(!grants.allows(script: "reader", secret: "API_TOKEN"))

        // Closing the question is not a yes either.
        let dismissed = await engine.run("reader", interactive: true, events: Recorder().record)
        #expect(dismissed.error?.message.contains("Cancelled") == true)
        #expect(!grants.allows(script: "reader", secret: "API_TOKEN"))

        // A yes hands the secret over, masked as ever, and is remembered.
        let agreed = Recorder { _ in .bool(true) }
        let allowed = await engine.run("reader", interactive: true, events: agreed.record)
        #expect(try json(allowed.resultJSON) as? NSDictionary == ["token": 12])
        #expect(grants.allows(script: "reader", secret: "API_TOKEN"))

        let later = Recorder()
        #expect(await engine.run("reader", events: later.record).error == nil)
        #expect(prompts(later).isEmpty)
    }

    @Test func aScriptRunByAnotherNeedsItsOwnPermission() async throws {
        // The pipeline may read the secret; the step it runs may not, and
        // does not inherit it.
        let grants = InMemorySecretGrants(["API_TOKEN": ["chain"]])
        let engine = makeEngine(
            ["chain": #"await secrets.get("API_TOKEN"); output.json(await run("reader"));"#, "reader": Self.reader],
            secrets: InMemorySecretStore(["API_TOKEN": "s3cr3t-value"]), grants: grants
        )
        #expect(await engine.run("chain").error?.message.contains("“Reader” has not been allowed") == true)

        let agreed = Recorder { _ in .bool(true) }
        #expect(await engine.run("chain", interactive: true, events: agreed.record).error == nil)
        #expect(prompts(agreed).map(\.message) == ["Allow “Reader” to use your saved secret “API_TOKEN”?"])
        #expect(grants.allows(script: "reader", secret: "API_TOKEN"))
    }

    @Test func grantsAreKeptInAFileAndFollowTheScript() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "rhino-grants-\(UUID().uuidString)/Secrets.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let grants = FileSecretGrants(file: file)
        #expect(!grants.allows(script: "weather", secret: "API_TOKEN"))

        grants.allow(script: "weather", secret: "API_TOKEN")
        grants.allow(script: "weather", secret: "API_TOKEN")
        grants.allow(script: "AI/digest", secret: "API_TOKEN")
        grants.allow(script: "weather", secret: "OTHER")
        #expect(FileSecretGrants(file: file).all() == ["API_TOKEN": ["AI/digest", "weather"], "OTHER": ["weather"]])
        // The file holds names only.
        #expect(try String(contentsOf: file, encoding: .utf8).contains("weather"))

        // A moved script keeps what it was allowed; the old id keeps nothing.
        grants.rename(script: "weather", to: "Home/weather")
        #expect(grants.allows(script: "Home/weather", secret: "OTHER"))
        #expect(!grants.allows(script: "weather", secret: "API_TOKEN"))

        grants.revoke(script: "AI/digest", secret: "API_TOKEN")
        #expect(grants.all() == ["API_TOKEN": ["Home/weather"], "OTHER": ["Home/weather"]])

        // A deleted script, or a removed secret, leaves nothing behind.
        grants.forget(secret: "OTHER")
        grants.forget(script: "Home/weather")
        #expect(grants.all().isEmpty)
    }
}
