import Foundation
import Testing
@testable import RhinoCore

/// `ScriptWriter` against the Anthropic stand-in: streaming a script, the prompts it sends, and how failures are explained.
@Suite struct ScriptWriterTests {
    private func makeWriter(apiKey: String = "test-key") -> ScriptWriter {
        ScriptWriter(apiKey: apiKey, baseURL: URL(string: "https://api.test")!, session: stubbedSession())
    }

    private func collect(_ job: ScriptWriter.Job, apiKey: String = "test-key") async throws -> [String] {
        var updates: [String] = []
        for try await source in makeWriter(apiKey: apiKey).stream(job) {
            updates.append(source)
        }
        return updates
    }

    private func failure(_ job: ScriptWriter.Job, apiKey: String = "test-key") async -> AIError.Reason? {
        do {
            _ = try await collect(job, apiKey: apiKey)
            return nil
        } catch {
            return (error as? AIError)?.reason
        }
    }

    @Test func streamsAScriptThatRuns() async throws {
        let updates = try await collect(.write(instruction: "Report the request"))

        // It grows as it arrives, and thinking never leaks into it.
        #expect(updates.count == 2)
        #expect(updates[0].count < updates[1].count)
        #expect(updates.allSatisfy { !$0.contains("SECRET THOUGHTS") })
        let source = try #require(updates.last)
        #expect(ScriptHeader.parse(source)["name"] == "Echo")

        // What was written is a real script: run it and read what it publishes.
        let (engine, _) = makeEngine(["echo": source])
        let recorder = Recorder()
        let summary = await engine.run("echo", events: recorder.record)
        #expect(summary.error == nil)
        #expect(recorder.outputs.map(\.name) == ["Request"])

        let sent = try #require(try json(summary.resultJSON) as? [String: Any])
        #expect(sent["model"] as? String == "claude-opus-5-5")
        #expect(sent["stream"] as? Bool == true)
        #expect(sent["maxTokens"] as? Int == 64000)
        #expect(sent["thinking"] as? String == "adaptive")
        #expect(sent["effort"] as? String == "medium")
        #expect(sent["fallbacks"] as? String == "default")
        #expect(sent["version"] as? String == "2026-10-21")
        #expect(sent["beta"] as? String == "server-side-fallback-2026-07-01")
        #expect(sent["cached"] as? Bool == true)
        #expect(sent["systemHasAPI"] as? Bool == true)
        #expect(sent["systemHasExample"] as? Bool == true)
        #expect((sent["user"] as? String)?.contains("Report the request") == true)
    }

    @Test func describesEachJobToTheModel() {
        let revise = ScriptWriter.userMessage(for: .revise(source: "output.log(1);", instruction: "Log 2 instead"))
        #expect(revise.contains("<script>\noutput.log(1);\n</script>"))
        #expect(revise.contains("Log 2 instead"))

        let fix = ScriptWriter.userMessage(for: .fix(source: "nope();", problem: "ReferenceError: Can't find variable: nope (line 1)"))
        #expect(fix.contains("<script>\nnope();\n</script>"))
        #expect(fix.contains("<failure>\nReferenceError: Can't find variable: nope (line 1)\n</failure>"))
    }

    @Test func systemPromptIsStableAndComplete() {
        // Identical on every call, or the prompt cache never hits.
        #expect(ScriptWriter.systemPrompt == ScriptWriter.systemPrompt)
        #expect(ScriptWriter.systemPrompt.contains(API.typeDefinitions))
        for name in ScriptCompiler.globals {
            #expect(ScriptWriter.systemPrompt.contains(name), "the prompt should mention \(name)")
        }
    }

    @Test func removesACodeFence() async throws {
        let updates = try await collect(.write(instruction: "FENCED please"))
        #expect(updates.last == "// @name Fenced\noutput.json(1 + 1).name(\"Two\");\n")
        #expect(ScriptWriter.clean("plain();") == "plain();\n")
        #expect(ScriptWriter.clean("\n\n") == "")
    }

    @Test func explainsFailures() async {
        #expect(await failure(.write(instruction: "x"), apiKey: "  ") == .missingKey)
        #expect(await failure(.write(instruction: "x"), apiKey: "bad-key") == .api(status: 401, kind: "authentication_error", message: "invalid x-api-key"))
        #expect(await failure(.write(instruction: "REFUSE this")) == .refused)
        #expect(await failure(.write(instruction: "TOO LONG")) == .truncated)
        #expect(await failure(.write(instruction: "OVERLOADED")) == .api(status: 200, kind: "overloaded_error", message: "Overloaded"))

        let missing = AIError(.missingKey, provider: "Anthropic")
        #expect(missing.errorDescription?.contains("Settings") == true)
        #expect(missing.errorDescription?.contains("Anthropic") == true)
        #expect(missing.needsSettings)
        let rejected = AIError(.api(status: 401, kind: "authentication_error", message: ""), provider: "OpenAI")
        #expect(rejected.errorDescription == "OpenAI did not accept the API key. Check it in Settings.")
        #expect(rejected.needsSettings)
        #expect(!AIError(.refused, provider: "OpenAI").needsSettings)
    }

    @Test func recognisesTheStarterTemplate() {
        #expect(ScriptStore.isStarter(""))
        #expect(ScriptStore.isStarter(ScriptStore.template(name: "Untitled")))
        #expect(ScriptStore.isStarter(ScriptStore.template(name: "My thing") + "\n\n"))
        #expect(!ScriptStore.isStarter(ScriptStore.template(name: "Untitled") + "output.log(1);"))
        #expect(!ScriptStore.isStarter("output.log(1);"))
    }
}
