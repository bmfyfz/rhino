import Foundation
import Testing
@testable import RhinoCore

/// `RunRecord`: storing a finished run and reading it back.
@Suite struct RunRecordTests {
    /// Runs a script and keeps it the way an app would.
    private func record(of source: String, answers: @escaping @Sendable (PromptRequest) -> PromptRequest.Answer = { _ in .cancelled }) async -> RunRecord {
        let (engine, _) = makeEngine(["job": source])
        let recorder = Recorder(answers: answers)
        let summary = await engine.run("job", interactive: true, events: recorder.record)

        var items: [RunRecord.Item] = []
        var spans: [UUID: HTTPSpan] = [:]
        for event in recorder.events {
            switch event {
            case .log(let entry): items.append(.log(entry))
            case .notification(let notification): items.append(.notification(notification))
            case .spanFinished(let span): spans[span.id] = span
            case .spanStarted(let span): items.append(.call(span))
            case .prompt(let request):
                items.append(.question(RunRecord.Question(request: request, askedAt: Date(), answer: "answered", formValues: nil)))
            default: break
            }
        }
        items = items.map { item in
            if case .call(let span) = item { .call(spans[span.id] ?? span) } else { item }
        }
        items += recorder.savedFiles.map { .file($0) }
        items += recorder.outputs.map { .output($0) }
        return RunRecord(id: UUID(), script: "job", isScheduled: true, summary: summary, runs: recorder.runs, items: items)
    }

    @Test func survivesBeingStoredAndReadBack() async throws {
        let original = await record(of: """
        const name = await input.ask("Who?");
        output.log("hello", name);
        const response = await get("https://example.test/users");
        await output.file("out.txt", "saved").name("The file");
        output.table([{ a: 1 }]).name("Rows");
        output.json({ ok: true }).name("Answer");
        notify("Done", "All saved");
        """, answers: { _ in .text("Ada") })

        let restored = try RunRecord(data: original.encoded())

        #expect(restored.id == original.id)
        #expect(restored.script == "job")
        #expect(restored.isScheduled)
        #expect(restored.summary.error == nil)
        #expect(restored.failed == false)
        #expect(restored.runs == original.runs)
        #expect(restored.items == original.items)
        #expect(restored.summary.resultJSON == original.summary.resultJSON)
        #expect(abs(restored.startedAt.timeIntervalSince(original.startedAt)) < 0.001)

        let names = restored.items.compactMap { item -> String? in
            switch item {
            case .file(let file): file.name
            case .output(let output): output.name
            default: nil
            }
        }
        #expect(names == ["The file", "Rows", "Answer"])
        #expect(restored.items.contains { if case .call(let span) = $0 { span.status == 200 } else { false } })
        #expect(restored.items.contains { if case .notification(let notification) = $0 { notification.title == "Done" } else { false } })
    }

    @Test func keepsTheErrorOfAFailedRun() async throws {
        let original = await record(of: "output.log('before');\nthrow new Error('it broke');")
        let restored = try RunRecord(data: original.encoded())

        #expect(restored.failed)
        #expect(restored.summary.error?.message == "it broke")
        #expect(restored.summary.error?.line == 2)
    }

    @Test func cutsLongBodiesShortWhenStored() async throws {
        var original = await record(of: #"await get("https://example.test/users");"#)
        let long = String(repeating: "x", count: RunRecord.maxStoredBody * 2)
        original.items = original.items.map { item in
            guard case .call(var span) = item else { return item }
            span.responseBody = long
            return .call(span)
        }

        let restored = try RunRecord(data: original.encoded())
        let body = try #require(restored.items.compactMap { item -> String? in
            if case .call(let span) = item { span.responseBody } else { nil }
        }.first)

        #expect(body.hasSuffix("… truncated"))
        #expect(body.utf8.count < RunRecord.maxStoredBody + 100)
        // What is on screen keeps the whole body.
        #expect(original.items.contains { if case .call(let span) = $0 { span.responseBody == long } else { false } })
    }

    @Test func aStoredQuestionBecomesASettledOne() async throws {
        let original = await record(of: """
        const answers = await input.form({ month: { options: ["Jan", "Feb"], required: true } }, { title: "Report" });
        output.json(answers);
        """, answers: { request in .form(["month": .option(1)]) })
        let restored = try RunRecord(data: original.encoded())

        let question = try #require(restored.items.compactMap { item -> RunRecord.Question? in
            if case .question(let question) = item { question } else { nil }
        }.first)
        let request = PromptRequest(question)

        #expect(request.kind == .form)
        #expect(request.message == "Report")
        #expect(request.fields.map(\.id) == ["month"])
        #expect(request.fields.first?.options == ["Jan", "Feb"])
        // Replying to a question from the past is harmless.
        request.reply(.cancelled)
    }
}
