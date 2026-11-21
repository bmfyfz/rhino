import Foundation
import Testing
@testable import RhinoCore

/// Files on the move: `download()` and `upload()`, attachments for `ai.ask()`, `ai.image()`, and the per-run limit on AI calls.
@Suite struct FileTransferTests {
    @Test func downloadsToAFileThatCanBeNamedAndRead() async throws {
        let (engine, runs) = makeEngine(["m": """
        const file = await download("https://example.test/text").name("The words");
        const again = await download("https://example.test/text", { name: "copy.txt" });
        const third = await download("https://example.test/text", { name: "copy.txt" });
        output.json({ name: file.name, ext: file.ext, size: file.size, text: await file.text(), again: again.name, third: third.name });
        """])
        let recorder = Recorder()
        let summary = await engine.run("m", events: recorder.record)

        #expect(summary.error == nil)
        let result = try #require(try json(summary.resultJSON) as? [String: Any])
        #expect(result["name"] as? String == "text.txt")
        #expect(result["ext"] as? String == "txt")
        #expect(result["size"] as? Int == 11)
        #expect(result["text"] as? String == "plain words")
        #expect(result["again"] as? String == "copy.txt")
        // A second file of the same name does not replace the first.
        #expect(result["third"] as? String == "copy 2.txt")

        // Each is one of the run's files, in its folder, under the name it was given.
        #expect(recorder.savedFiles.map(\.name) == ["The words", nil, nil])
        #expect(recorder.savedFiles.allSatisfy { $0.url.path.hasPrefix(runs.path) })
        #expect(try String(contentsOf: recorder.savedFiles[0].url, encoding: .utf8) == "plain words")
        // And each is on record as a call, without the bytes.
        #expect(recorder.finishedSpans.count == 3)
        #expect(recorder.finishedSpans[0].responseBody?.hasPrefix("[saved as text.txt") == true)
    }

    @Test func aFailedDownloadFailsTheRun() async throws {
        let (engine, _) = makeEngine(["m": #"output.log("before");\#nawait download("https://example.test/missing");"#])
        let recorder = Recorder()
        let summary = await engine.run("m", events: recorder.record)

        #expect(summary.error?.message == "GET https://example.test/missing failed with status 500")
        #expect(summary.error?.line == 2)
        #expect(recorder.savedFiles.isEmpty)
    }

    @Test func uploadsFilesAsAFormOrAsTheBody() async throws {
        let (engine, _) = makeEngine(["m": """
        const file = await download("https://example.test/text");
        const form = await upload("https://example.test/echo", { title: "Receipt", count: 2, photo: file });
        const raw = await put("https://example.test/echo", file);
        output.json({ form: form.data, raw: raw.data });
        """])
        let recorder = Recorder()
        let summary = await engine.run("m", events: recorder.record)

        #expect(summary.error == nil)
        let result = try #require(try json(summary.resultJSON) as? [String: [String: Any]])
        let form = try #require(result["form"])
        let type = try #require(form["contentType"] as? String)
        #expect(form["method"] as? String == "POST")
        #expect(type.hasPrefix("multipart/form-data; boundary=rhino-"))
        let sent = try #require(form["body"] as? String)
        #expect(sent.contains("Content-Disposition: form-data; name=\"title\"\r\n\r\nReceipt\r\n"))
        #expect(sent.contains("name=\"count\"\r\n\r\n2\r\n"))
        #expect(sent.contains("name=\"photo\"; filename=\"text.txt\"\r\nContent-Type: text/plain\r\n\r\nplain words\r\n"))
        #expect(sent.hasSuffix("--\r\n"))

        let raw = try #require(result["raw"])
        #expect(raw["method"] as? String == "PUT")
        #expect(raw["contentType"] as? String == "text/plain")
        #expect(raw["body"] as? String == "plain words")

        // The record says what was sent, not the bytes.
        #expect(recorder.finishedSpans[1].requestBody?.contains("photo: [file text.txt") == true)
        #expect(recorder.finishedSpans[2].requestBody?.hasPrefix("[file text.txt") == true)
    }

    @Test func sendsFilesToTheModelInEachProvidersFormat() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "rhino-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let picture = folder.appending(path: "photo.PNG")
        let notes = folder.appending(path: "notes.md")
        let paper = folder.appending(path: "paper.pdf")
        let archive = folder.appending(path: "data.zip")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: picture)
        try Data("# Notes".utf8).write(to: notes)
        try Data("%PDF-1.7".utf8).write(to: paper)
        try Data([0xFF, 0xFE, 0x00, 0xC3]).write(to: archive)

        let files = try [picture, notes, paper].map { try AIAttachment(url: $0) }
        #expect(files.map(\.kind) == [.image, .text, .pdf])
        #expect(files.map(\.mediaType) == ["image/png", "text/plain", "application/pdf"])
        #expect(throws: AIAttachment.Unreadable.self) { try AIAttachment(url: archive) }
        #expect(throws: AIAttachment.Unreadable.self) { try AIAttachment(url: folder.appending(path: "nothing.png")) }

        let question = AIQuestion(prompt: "What is this?", attachments: files)
        let claude = try AIService.anthropicBody(for: question, model: "claude-opus-5-5")
        let blocks = try #require((claude["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
        #expect(blocks.map { $0["type"] as? String } == ["image", "text", "document", "text"])
        let source = try #require(blocks[0]["source"] as? [String: String])
        #expect(source == ["type": "base64", "media_type": "image/png", "data": "iVBORw=="])
        #expect(blocks[1]["text"] as? String == "<file name=\"notes.md\">\n# Notes\n</file>")
        #expect((blocks[2]["source"] as? [String: String])?["media_type"] == "application/pdf")
        #expect(blocks[3]["text"] as? String == "What is this?")

        let openAI = try AIService.openAIBody(for: question, model: "gpt-test", baseURL: URL(string: "https://api.openai.com/v1")!)
        let parts = try #require((openAI["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]])
        #expect(parts.map { $0["type"] as? String } == ["image_url", "text", "file", "text"])
        #expect((parts[0]["image_url"] as? [String: String])?["url"] == "data:image/png;base64,iVBORw==")
        #expect((parts[2]["file"] as? [String: String])?["filename"] == "paper.pdf")
        #expect((parts[2]["file"] as? [String: String])?["file_data"]?.hasPrefix("data:application/pdf;base64,") == true)

        // Without files the prompt stays plain text, as before.
        let plain = try AIService.openAIBody(for: AIQuestion(prompt: "Hi"), model: "gpt-test", baseURL: URL(string: "https://api.openai.com/v1")!)
        #expect((plain["messages"] as? [[String: Any]])?.last?["content"] as? String == "Hi")
    }

    private func runAI(_ source: String, maxAICalls: Int = Engine.defaultMaxAICalls) async -> (summary: RunSummary, recorder: Recorder) {
        let engine = Engine(
            provider: Scripts(sources: ["m": source]),
            runsDirectory: FileManager.default.temporaryDirectory.appending(path: "rhino-tests-\(UUID().uuidString)"),
            session: TestAI.session,
            ai: TestAI(services: [TestAI.openAI], session: TestAI.session)
        )
        let recorder = Recorder()
        let summary = await engine.run("m", maxAICalls: maxAICalls, events: recorder.record)
        return (summary, recorder)
    }

    @Test func aScriptHandsFilesToAIAsk() async throws {
        let (summary, recorder) = await runAI("""
        const file = await download("https://example.test/text");
        const path = await output.file("more.txt", "second file");
        await ai.ask("ECHO these", { files: [file, path] });
        """)

        #expect(summary.error == nil)
        let asked = try #require(recorder.finishedSpans.last?.requestBody)
        #expect(asked.hasPrefix("Files: text.txt (11 bytes), more.txt (11 bytes)\n\nECHO these"))

        let unreadable = await runAI(#"await ai.ask("Look", { files: ["nothing-here.png"] });"#)
        #expect(unreadable.summary.error?.message.contains("cannot read the file") == true)
        let wrong = await runAI(#"await ai.ask("Look", { files: [42] });"#)
        #expect(wrong.summary.error?.message.contains("`files` holds files") == true)
    }

    @Test func makesAPictureAndKeepsItAsAFile() async throws {
        let (summary, recorder) = await runAI("""
        const cover = await ai.image("A lighthouse at dawn").name("Cover");
        const wide = await ai.image("A banner", { size: "1536x1024", transparent: true, model: "custom-painter", name: "banner.png" });
        output.json({ cover: cover.name, coverText: await cover.text(), wide: wide.name, wideText: await wide.text() });
        """)

        #expect(summary.error == nil)
        let result = try #require(try json(summary.resultJSON) as? [String: String])
        // With no model named, the newest full-size picture model the key lists is used.
        #expect(result["cover"] == "picture.png")
        #expect(result["coverText"]?.hasSuffix("PNG gpt-image-2 1024x1024 opaque A lighthouse at dawn") == true)
        #expect(result["wide"] == "banner.png")
        #expect(result["wideText"]?.hasSuffix("PNG custom-painter 1536x1024 transparent A banner") == true)

        #expect(recorder.savedFiles.map(\.name) == ["Cover", nil])
        let span = try #require(recorder.finishedSpans.first)
        #expect(span.method == "AI")
        #expect(span.url == "OpenAI · gpt-image-2")
        #expect(span.requestBody == "Picture: A lighthouse at dawn")
        #expect(span.responseBody?.hasPrefix("[picture saved as picture.png") == true)

        #expect(AIService.pictureModel(among: ["gpt-4", "dall-e-2", "dall-e-3"]) == "dall-e-3")
        #expect(AIService.pictureModel(among: ["gpt-image-1-mini"]) == "gpt-image-1-mini")
        #expect(AIService.pictureModel(among: ["gpt-4", "claude"]) == nil)
    }

    @Test func saysWhenAProviderCannotMakePictures() async throws {
        let engine = Engine(
            provider: Scripts(sources: ["m": #"await ai.image("A cat");"#, "blank": #"await ai.image("  ");"#]),
            runsDirectory: FileManager.default.temporaryDirectory.appending(path: "rhino-tests-\(UUID().uuidString)"),
            session: TestAI.session,
            ai: TestAI(services: [TestAI.claude], session: TestAI.session)
        )
        let summary = await engine.run("m", events: Recorder().record)
        #expect(summary.error?.message == "Anthropic cannot be used for making pictures. Choose another provider for it.")
        let blank = await engine.run("blank", events: Recorder().record)
        #expect(blank.error?.message.contains("needs a description") == true)
    }

    @Test func aRunMayAskTheAIOnlySoOften() async throws {
        let (summary, recorder) = await runAI("""
        for (let i = 1; i <= 5; i++) {
          await ai.ask(`ECHO ${i}`);
          output.log(`asked ${i}`);
        }
        """, maxAICalls: 3)

        #expect(summary.error?.message.contains("already asked the AI 3 times") == true)
        #expect(summary.error?.line == 2)
        #expect(recorder.logs == ["asked 1", "asked 2", "asked 3"])
        // The refused call never reached the provider.
        #expect(recorder.finishedSpans.count == 3)
    }
}
