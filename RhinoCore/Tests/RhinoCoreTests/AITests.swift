import Foundation
import Testing
@testable import RhinoCore

/// `ai.ask()` and model lists against the Anthropic and OpenAI-style stand-ins, and writing scripts with another provider.
@Suite struct AITests {
    private func run(_ source: String, services: [AIService] = [TestAI.claude, TestAI.openAI, TestAI.local]) async -> (summary: RunSummary, recorder: Recorder) {
        let engine = Engine(
            provider: Scripts(sources: ["m": source]),
            runsDirectory: FileManager.default.temporaryDirectory.appending(path: "rhino-tests-\(UUID().uuidString)"),
            session: TestAI.session,
            secrets: InMemorySecretStore(["TOKEN": "s3cr3t-value"]),
            ai: services.isEmpty ? nil : TestAI(services: services, session: TestAI.session)
        )
        let recorder = Recorder()
        let summary = await engine.run("m", events: recorder.record)
        return (summary, recorder)
    }

    @Test func asksClaudeAndGetsText() async throws {
        let (summary, recorder) = await run("""
        const answer = await ai.ask("ECHO please", { system: "Be brief." });
        output.json(JSON.parse(answer));
        """)

        #expect(summary.error == nil)
        let sent = try #require(try json(summary.resultJSON) as? [String: Any])
        #expect(sent["model"] as? String == "claude-opus-5-5")
        #expect(sent["stream"] as? Bool == true)
        #expect(sent["maxTokens"] as? Int == 16000)
        #expect(sent["plainSystem"] as? String == "Be brief.")
        #expect(sent["user"] as? String == "ECHO please")
        #expect(sent["fallbacks"] as? String == "default")
        // Thinking and effort are the model's own business unless the script says so.
        #expect(sent["thinking"] as? String == "")
        #expect(sent["effort"] as? String == "")

        // The call is on record like an HTTP call, with what it used.
        let span = try #require(recorder.finishedSpans.first)
        #expect(span.method == "AI")
        #expect(span.url == "Anthropic · claude-opus-5-5")
        #expect(span.status == 200)
        #expect(span.requestBody?.contains("System:\nBe brief.") == true)
        #expect(span.requestBody?.contains("ECHO please") == true)
        #expect(span.responseHeaders["input tokens"] == "42")
        #expect(span.responseHeaders["output tokens"] == "10")
    }

    @Test func returnsDataInTheShapeAskedFor() async throws {
        let (summary, _) = await run("""
        const review = await ai.ask("How was it?", { returns: { mood: ai.oneOf("happy", "sad"), score: "integer" } });
        const colours = await ai.ask("Name two colours", { returns: ["string"] });
        output.json({ mood: review.mood, score: review.score, colours });
        """)

        #expect(summary.error == nil)
        let result = try #require(try json(summary.resultJSON) as? [String: Any])
        #expect(result["mood"] as? String == "happy")
        #expect(result["score"] as? Int == 4)
        // A list was asked for, so a list comes back, not the object it travelled in.
        #expect(result["colours"] as? [String] == ["red", "green"])
    }

    @Test func turnsTheShorthandIntoASchema() async throws {
        let body = try AIService.anthropicBody(
            for: AIQuestion(prompt: "x", effort: "low", schema: #"{"type":"object","properties":{"a":{"type":"string"}},"required":["a"],"additionalProperties":false}"#),
            model: "claude-haiku-5-5"
        )
        let output = try #require(body["output_config"] as? [String: Any])
        #expect(output["effort"] as? String == "low")
        let format = try #require(output["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect((format["schema"] as? [String: Any])?["required"] as? [String] == ["a"])
        // Only the default model is known to take a fallback.
        #expect(body["fallbacks"] == nil)

        let (summary, recorder) = await run("""
        await ai.ask("Describe it", { returns: { title: "string", tags: ["string"], kind: ai.oneOf("a", "b"), parts: [{ n: "number", ok: "boolean" }] } });
        """)
        #expect(summary.error == nil)
        let asked = try #require(recorder.finishedSpans.first?.requestBody)
        let schema = try #require(try json(String(asked[asked.range(of: "Answer as JSON matching:\n")!.upperBound...])) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: [String: Any]])
        #expect(schema["required"] as? [String] == ["title", "tags", "kind", "parts"])
        #expect(schema["additionalProperties"] as? Bool == false)
        #expect(properties["title"]?["type"] as? String == "string")
        #expect((properties["tags"]?["items"] as? [String: Any])?["type"] as? String == "string")
        #expect(properties["kind"]?["enum"] as? [String] == ["a", "b"])
        let part = try #require(properties["parts"]?["items"] as? [String: Any])
        #expect(part["required"] as? [String] == ["n", "ok"])
        #expect(part["additionalProperties"] as? Bool == false)
    }

    @Test func asksAnOpenAIStyleProviderByName() async throws {
        let (summary, recorder) = await run("""
        const answer = await ai.ask("ECHO please", { provider: "openai", system: "Be brief.", maxTokens: 500, effort: "high" });
        const data = await ai.ask("How was it?", { provider: "OpenAI", returns: { mood: "string", score: "integer" } });
        output.json({ sent: JSON.parse(answer), data });
        """)

        #expect(summary.error == nil)
        let result = try #require(try json(summary.resultJSON) as? [String: Any])
        let sent = try #require(result["sent"] as? [String: Any])
        #expect(sent["model"] as? String == "gpt-test")
        #expect(sent["path"] as? String == "/v1/chat/completions")
        #expect(sent["authorization"] as? String == "Bearer sk-test")
        #expect(sent["system"] as? String == "Be brief.")
        #expect(sent["user"] as? String == "ECHO please")
        #expect(sent["effort"] as? String == "high")
        // Not streamed, so the tokens used are reported; and OpenAI's own name for the limit.
        #expect(sent["stream"] as? Bool == false)
        #expect(sent["maxCompletionTokens"] as? Int == 500)
        #expect(sent["maxTokens"] as? Int == 0)
        // The stand-in fences its JSON, as some models do; the data still arrives.
        #expect((result["data"] as? [String: Any])?["mood"] as? String == "happy")

        let span = try #require(recorder.finishedSpans.first)
        #expect(span.url == "OpenAI · gpt-test-served")
        #expect(span.responseHeaders["input tokens"] == "7")
        #expect(span.responseHeaders["output tokens"] == "3")
    }

    @Test func aLocalServerNeedsNoKeyAndTakesAnotherModel() async throws {
        let (summary, _) = await run(#"output.json(JSON.parse(await ai.ask("ECHO", { provider: "local", model: "other-model", maxTokens: 64 })));"#)

        #expect(summary.error == nil)
        let sent = try #require(try json(summary.resultJSON) as? [String: Any])
        #expect(sent["model"] as? String == "other-model")
        #expect(sent["host"] as? String == "localhost")
        #expect(sent["authorization"] as? String == "")
        // Servers that copied the format know the limit by its old name.
        #expect(sent["maxTokens"] as? Int == 64)
        #expect(sent["maxCompletionTokens"] as? Int == 0)
    }

    @Test func explainsWhatWentWrong() async throws {
        var noKey = TestAI.openAI
        noKey.apiKey = ""
        var noModel = TestAI.openAI
        noModel.model = ""
        var badKey = TestAI.openAI
        badKey.apiKey = "bad-key"

        func message(_ source: String, _ services: [AIService]) async -> String {
            await run(source, services: services).summary.error?.message ?? ""
        }
        let ask = #"output.log("before");\#nawait ai.ask("Hello");"#

        #expect(await message(ask, []) == "ai.ask() is not available here.")
        #expect(await message(ask, [noKey]) == "Add an API key for OpenAI in Settings to use AI.")
        #expect(await message(ask, [noModel]) == "Choose a model for OpenAI in Settings.")
        #expect(await message(ask, [badKey]) == "OpenAI did not accept the API key. Check it in Settings.")
        #expect(await message(#"await ai.ask("BUSY");"#, [TestAI.openAI]).contains("too many requests"))
        #expect(await message(#"await ai.ask("TOO LONG");"#, [TestAI.openAI]).contains("cut off"))
        #expect(await message(#"await ai.ask("REFUSE");"#, [TestAI.openAI]).contains("declined"))
        #expect(await message(#"await ai.ask("REFUSE");"#, [TestAI.claude]).contains("declined"))
        #expect(await message(#"await ai.ask("   ");"#, [TestAI.claude]).contains("ai.ask() needs a question"))
        #expect(await message(#"await ai.ask("x", { returns: "text" });"#, [TestAI.claude]).contains("is not a type"))
        #expect(await message(#"await ai.ask("x", { effort: "extreme" });"#, [TestAI.claude]).contains("effort is"))

        // The failure points at the script's own line, and is on record.
        let (summary, recorder) = await run(ask, services: [badKey])
        #expect(summary.error?.line == 2)
        #expect(recorder.finishedSpans.first?.error?.contains("did not accept") == true)
    }

    @Test func theExampleScriptIsValidAndAsksOnce() async throws {
        let source = try #require(Examples.all.first { $0.id == "AI/sort-feedback" }?.source)
        let (summary, recorder) = await run(source)

        // The stand-in does not answer in the example's shape, so only how
        // far it got matters: it parsed, used its default, and asked once.
        #expect(summary.error?.name != "SyntaxError")
        #expect(recorder.logs.contains("Asking the AI about 3 comments"))
        #expect(recorder.finishedSpans.count == 1)
        #expect(recorder.finishedSpans.first?.requestBody?.contains("2. I was charged twice this month.") == true)
    }

    @Test func keepsSecretsOutOfTheRecord() async throws {
        let (summary, recorder) = await run("""
        const token = await secrets.get("TOKEN", "A token");
        await ai.ask(`ECHO ${token}`);
        """)

        #expect(summary.error == nil)
        let span = try #require(recorder.finishedSpans.first)
        #expect(span.requestBody?.contains("s3cr3t-value") == false)
        #expect(span.responseBody?.contains("s3cr3t-value") == false)
    }

    @Test func listsTheModelsAKeyCanUse() async throws {
        #expect(try await TestAI.claude.models(session: TestAI.session) == ["claude-opus-5-5", "claude-haiku-5-5"])
        // Sorted, without the ones that cannot chat, and under the names the provider takes.
        #expect(try await TestAI.openAI.models(session: TestAI.session) == ["alpha-chat", "gemini-test", "zeta-chat"])

        var badKey = TestAI.openAI
        badKey.apiKey = "bad-key"
        await #expect(throws: AIError(.api(status: 401, kind: "authentication_error", message: "Incorrect API key provided"), provider: "OpenAI")) {
            try await badKey.models(session: TestAI.session)
        }
        var noKey = TestAI.openAI
        noKey.apiKey = ""
        await #expect(throws: AIError(.missingKey, provider: "OpenAI")) {
            try await noKey.models(session: TestAI.session)
        }
    }

    @Test func writesScriptsWithAnotherProvider() async throws {
        let writer = ScriptWriter(service: TestAI.openAI, session: TestAI.session)
        var updates: [String] = []
        for try await source in writer.stream(.write(instruction: "Report the request")) {
            updates.append(source)
        }

        // It arrives in pieces and ends up a script that runs.
        #expect(updates.count == 2)
        let source = try #require(updates.last)
        #expect(ScriptHeader.parse(source)["name"] == "Echo")
        let (engine, _) = makeEngine(["echo": source])
        let summary = await engine.run("echo", events: Recorder().record)
        let sent = try #require(try json(summary.resultJSON) as? [String: Any])
        #expect(sent["model"] as? String == "gpt-test")
        #expect(sent["stream"] as? Bool == true)
        #expect(sent["systemHasAPI"] as? Bool == true)
        #expect((sent["user"] as? String)?.contains("Report the request") == true)

        await #expect(throws: AIError(.truncated, provider: "OpenAI")) {
            for try await _ in writer.stream(.write(instruction: "TOO LONG")) {}
        }

        // Another Claude model gets only what every Claude model accepts.
        let body = AIService.anthropicWriterBody(system: "s", prompt: "p", model: "claude-haiku-5-5")
        #expect(body["thinking"] == nil)
        #expect(body["fallbacks"] == nil)
        #expect(body["max_tokens"] as? Int == 32000)
    }
}
