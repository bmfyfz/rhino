import Foundation
import Testing
@testable import RhinoCore

/// Things that must hold however a script is written: a run can always be
/// stopped, bad input cannot crash the host, and secrets stay out of what is kept.
@Suite struct HardeningTests {
    private func makeEngine(_ source: String, secrets: [String: String] = [:]) -> Engine {
        Engine(
            provider: Scripts(sources: ["m": source]),
            runsDirectory: FileManager.default.temporaryDirectory.appending(path: "rhino-tests-\(UUID().uuidString)"),
            session: stubbedSession(),
            secrets: InMemorySecretStore(secrets)
        )
    }

    /// Starts a script, waits for it to log "ready", cancels it, and returns
    /// how it ended. Fails the test if the run does not end within a second.
    private func cancelled(_ source: String, interactive: Bool = false) async throws -> RunSummary {
        let engine = makeEngine(source)
        let recorder = Recorder()
        // Questions are left unanswered: the recorder would otherwise reply to them.
        let task = Task {
            await engine.run("m", interactive: interactive) { event in
                if case .prompt = event { return }
                recorder.record(event)
            }
        }
        while !recorder.logs.contains("ready") { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()

        let watchdog = Task {
            try await Task.sleep(for: .seconds(1))
            Issue.record("The run did not stop within a second of being cancelled")
        }
        let summary = await task.value
        watchdog.cancel()
        return summary
    }

    @Test func aScriptThatRetriesOnErrorsCanStillBeStopped() async throws {
        let summary = try await cancelled("""
        output.log("ready");
        while (true) {
          try { await sleep(60000); } catch (error) { /* try again */ }
        }
        """)
        #expect(summary.error?.isCancellation == true)
        #expect(summary.error?.message == "Run cancelled")
    }

    @Test func aScriptWaitingForNothingCanBeStopped() async throws {
        let summary = try await cancelled("""
        output.log("ready");
        await new Promise(() => {});
        """)
        #expect(summary.error?.isCancellation == true)
    }

    @Test func aScriptWaitingForAnAnswerCanBeStopped() async throws {
        let summary = try await cancelled("""
        output.log("ready");
        await input.ask("Anyone there?");
        output.json("not reached");
        """, interactive: true)
        #expect(summary.error?.isCancellation == true)
        #expect(summary.resultJSON == nil)
    }

    @Test func aFailureIsNotACancellation() async {
        let summary = await makeEngine("throw new Error('broke');").run("m", events: Recorder().record)
        #expect(summary.error?.isCancellation == false)
    }

    @Test func absurdSleepsDoNotCrash() async throws {
        // Each of these used to trap or hang; cancelling shows the run is alive and waiting.
        for amount in ["1e24", "Number.MAX_VALUE", "Infinity"] {
            let summary = try await cancelled("output.log('ready');\nawait sleep(\(amount));")
            #expect(summary.error?.isCancellation == true, "sleep(\(amount))")
        }
        let quick = await makeEngine("await sleep(-5); await sleep(NaN); await sleep('soon'); output.json('done');").run("m", events: Recorder().record)
        #expect(quick.error == nil)
    }

    // MARK: - Secrets

    static let secret = "tok/en+with=odd&chars"

    /// Everything a run leaves behind, as one text, to search for a secret.
    private func everythingKept(_ summary: RunSummary, _ recorder: Recorder) throws -> String {
        var items: [RunRecord.Item] = recorder.events.compactMap { event in
            switch event {
            case .log(let entry): .log(entry)
            case .spanFinished(let span): .call(span)
            case .notification(let notification): .notification(notification)
            default: nil
            }
        }
        items += recorder.outputs.map { .output($0) } + recorder.savedFiles.map { .file($0) }
        let record = RunRecord(id: UUID(), script: "m", isScheduled: false, summary: summary, runs: recorder.runs, items: items)
        return String(decoding: try record.encoded(), as: UTF8.self)
    }

    @Test func aSecretStaysOutOfErrorsOutputsAndNames() async throws {
        let engine = makeEngine("""
        const token = await secrets.get("TOKEN", "A token");
        output.json({ token }).name(`Result for ${token}`);
        output.text(`The token is ${token}`);
        output.table([{ token }]);
        await output.file("note.txt", "x").name(`File for ${token}`);
        notify("Done", token);
        // The address goes into the error, key and all, once as typed and once encoded.
        await get("https://example.test/missing", { query: { api_key: token }, headers: { Authorization: "Bearer other-credential", "X-Custom": token } });
        """, secrets: ["TOKEN": Self.secret])
        let recorder = Recorder()
        let summary = await engine.run("m", events: recorder.record)

        #expect(summary.error?.message.contains("failed with status 500") == true)
        let kept = try everythingKept(summary, recorder)
        #expect(!kept.contains(Self.secret))
        #expect(!kept.contains("tok%2Fen%2Bwith%3Dodd%26chars"))
        #expect(!kept.contains("tok\\/en+with=odd&chars"))
        // A header that exists to carry credentials is never recorded, secret or not.
        #expect(!kept.contains("other-credential"))
        #expect(kept.contains(SecretMasker.replacement))
        // The script itself still got the real thing: the request was made with it.
        #expect(recorder.finishedSpans.last?.url.contains("api_key=") == true)
    }

    @Test func whatIsTypedIntoASecretQuestionIsASecret() async throws {
        let engine = makeEngine("""
        const password = await input.ask("Password?", { type: "secret" });
        const login = await input.form({ user: "User", pin: { type: "secret" } });
        output.log("Typed", password, "and", login.pin, "by", login.user);
        output.json({ password, pin: login.pin });
        throw new Error(`Rejected ${password}`);
        """)
        let recorder = Recorder { request in
            request.kind == .form ? .form(["user": .text("ada"), "pin": .text("90210-pin")]) : .text("hunter2-typed")
        }
        let summary = await engine.run("m", interactive: true, events: recorder.record)

        let kept = try everythingKept(summary, recorder)
        #expect(!kept.contains("hunter2-typed"))
        #expect(!kept.contains("90210-pin"))
        // What is not secret is left alone.
        #expect(recorder.logs.first?.contains("by ada") == true)
        #expect(summary.error?.message == "Rejected \(SecretMasker.replacement)")
    }

    @Test func masksEveryFormASecretTravelsIn() {
        var masker = SecretMasker()
        #expect(masker.mask("nothing to hide") == "nothing to hide")
        masker.add("a\"b\\c d/e")
        masker.add("abc")   // too short to be worth blanking
        let dots = SecretMasker.replacement

        #expect(masker.mask("x a\"b\\c d/e y") == "x \(dots) y")
        #expect(masker.mask("?k=a%22b%5Cc%20d%2Fe&z") == "?k=\(dots)&z")
        #expect(masker.mask(#"{"k":"a\"b\\c d\/e"}"#) == #"{"k":"\#(dots)"}"#)
        #expect(masker.mask(Data("a\"b\\c d/e".utf8).base64EncodedString()) == dots)
        #expect(masker.mask("abc stays") == "abc stays")

        let headers = masker.mask(headers: ["Authorization": "Bearer zzz", "Cookie": "s=1", "Accept": "a\"b\\c d/e", "X-API-Key": "k"])
        #expect(headers == ["Authorization": dots, "Cookie": dots, "Accept": dots, "X-API-Key": dots])
    }
}
