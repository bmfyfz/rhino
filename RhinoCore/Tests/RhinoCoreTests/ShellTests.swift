import Foundation
import Testing
@testable import RhinoCore

/// `shell()`: running commands in the user's shell.
@Suite struct ShellTests {
    private func run(_ source: String, secrets: [String: String] = [:]) async -> (summary: RunSummary, recorder: Recorder) {
        let engine = Engine(
            provider: Scripts(sources: ["m": source]),
            runsDirectory: FileManager.default.temporaryDirectory.appending(path: "rhino-tests-\(UUID().uuidString)"),
            session: stubbedSession(),
            secrets: InMemorySecretStore(secrets)
        )
        let recorder = Recorder()
        let summary = await engine.run("m", events: recorder.record)
        return (summary, recorder)
    }

    @Test func runsACommandAndGivesBackWhatItPrinted() async throws {
        let (summary, recorder) = await run("""
        const hello = await shell("echo hello; echo more; echo oops >&2");
        const upper = await shell("tr a-z A-Z", { input: "shout" });
        const where = await shell("pwd", { cwd: "/tmp" });
        const named = await shell("echo $GREETING", { env: { GREETING: "hi there" } });
        output.json({ text: hello.text, lines: hello.lines, stderr: hello.stderr.trim(), code: hello.code, ok: hello.ok,
          upper: upper.stdout, where: where.text, named: named.text });
        """)

        #expect(summary.error == nil)
        let result = try #require(try json(summary.resultJSON) as? [String: Any])
        #expect(result["text"] as? String == "hello\nmore")
        #expect(result["lines"] as? [String] == ["hello", "more"])
        #expect(result["stderr"] as? String == "oops")
        #expect(result["code"] as? Int == 0)
        #expect(result["ok"] as? Bool == true)
        #expect(result["upper"] as? String == "SHOUT")
        #expect((result["where"] as? String)?.hasSuffix("/tmp") == true)
        #expect(result["named"] as? String == "hi there")

        // Each command is on record, with what it printed.
        let first = try #require(recorder.finishedSpans.first)
        #expect(first.method == "SH")
        #expect(first.url == "echo hello; echo more; echo oops >&2")
        #expect(first.status == 200)
        #expect(first.responseHeaders["exit code"] == "0")
        #expect(first.responseBody?.contains("hello") == true)
        #expect(recorder.finishedSpans[1].requestBody == "shout")
    }

    @Test func aCommandThatFailsThrowsUnlessAskedNotTo() async throws {
        let (failed, recorder) = await run("output.log('before');\nawait shell('echo nope >&2; exit 3');")
        #expect(failed.error?.message == "`echo nope >&2; exit 3` failed with exit code 3: nope")
        #expect(failed.error?.line == 2)
        #expect(recorder.finishedSpans.first?.status == 500)

        let (looked, _) = await run("""
        const result = await shell("exit 7", { throwOnError: false });
        let caught = null;
        try { await shell("definitely-not-a-command-xyz"); } catch (error) { caught = error.result.code; }
        output.json({ code: result.code, ok: result.ok, caught });
        """)
        #expect(looked.error == nil)
        let result = try #require(try json(looked.resultJSON) as? [String: Any])
        #expect(result["code"] as? Int == 7)
        #expect(result["ok"] as? Bool == false)
        #expect(result["caught"] as? Int == 127)

        #expect(await run("await shell('  ');").summary.error?.message.contains("needs a command") == true)
    }

    @Test func stopsWhenTimeRunsOutOrTheRunIsStopped() async throws {
        let (summary, recorder) = await run("await shell('sleep 30', { timeout: 200 });")
        #expect(summary.error?.message.contains("took too long and was stopped") == true)
        #expect(summary.duration < 5)
        #expect(recorder.finishedSpans.first?.error?.hasPrefix("Stopped after") == true)

        // Stopping the run stops the command it is waiting for.
        let engine = Engine(provider: Scripts(sources: ["m": "output.log('ready');\nawait shell('sleep 30');"]), runsDirectory: FileManager.default.temporaryDirectory.appending(path: "rhino-tests-\(UUID().uuidString)"))
        let waiting = Recorder()
        let task = Task { await engine.run("m", events: waiting.record) }
        while !waiting.logs.contains("ready") { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let stopped = await task.value
        #expect(stopped.error?.isCancellation == true)
        #expect(stopped.duration < 5)
    }

    @Test func keepsSecretsOutOfTheRecord() async throws {
        let (summary, recorder) = await run("""
        const token = await secrets.get("TOKEN", "A token");
        const echoed = await shell(`echo "Bearer ${token}"`, { input: token });
        output.json(echoed.text.length);
        """, secrets: ["TOKEN": "s3cr3t-value"])

        #expect(summary.error == nil)
        // The command itself got the real thing.
        #expect(try json(summary.resultJSON) as? Int == "Bearer s3cr3t-value".count)
        let span = try #require(recorder.finishedSpans.first)
        #expect(!span.url.contains("s3cr3t-value"))
        #expect(span.responseBody?.contains("s3cr3t-value") == false)
        #expect(span.requestBody?.contains("s3cr3t-value") == false)
    }

    @Test func handlesALotOfOutput() async throws {
        let (summary, _) = await run(#"const big = await shell("yes line | head -n 200000"); output.json(big.lines.length);"#)
        #expect(summary.error == nil)
        #expect(try json(summary.resultJSON) as? Int == 200_000)
    }
}
