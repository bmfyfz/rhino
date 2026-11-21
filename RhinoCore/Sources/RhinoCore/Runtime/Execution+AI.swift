import Foundation
import JavaScriptCore

// `ai.ask()` and `ai.image()`.
extension Execution {
    // MARK: - Asking and making pictures

    /// `ai.ask()`. Recorded like an HTTP call, so the question, the answer,
    /// how long it took and what it used can be looked at afterwards.
    func askAI(runID: String, arguments: JSValue, callback: JSValue) {
        guard let id = register(callback) else { return }
        guard let ai else {
            return settle(id, error: "ai.ask() is not available here.")
        }
        aiCalls += 1
        guard aiCalls <= maxAICalls else {
            return settle(id, error: "This run has already asked the AI \(maxAICalls) times, the most one run may. Ask about several items in one call, or raise the limit in Settings.")
        }

        var attachments: [AIAttachment] = []
        do {
            for path in arguments.forProperty("files").toArray() as? [String] ?? [] {
                attachments.append(try AIAttachment(url: resolve(path: path)))
            }
        } catch {
            return settle(id, error: error.localizedDescription)
        }

        func text(_ name: String) -> String? {
            let value = arguments.forProperty(name)
            return value?.isString == true ? value?.toString() : nil
        }
        let maxTokens = arguments.forProperty("maxTokens").flatMap { $0.isNumber ? Int($0.toInt32()) : nil }
        let question = AIQuestion(
            prompt: text("prompt") ?? "",
            system: text("system"),
            provider: text("provider"),
            model: text("model"),
            maxTokens: maxTokens,
            effort: text("effort"),
            schema: text("schema"),
            attachments: attachments
        )

        var asked = question.prompt
        if let system = question.system { asked = "System:\n\(system)\n\nPrompt:\n\(asked)" }
        if !attachments.isEmpty {
            let files = attachments.map { "\($0.name) (\($0.data.count.formatted(.byteCount(style: .file))))" }
            asked = "Files: \(files.joined(separator: ", "))\n\n\(asked)"
        }
        if let schema = question.schema { asked += "\n\nAnswer as JSON matching:\n\(schema)" }
        var span = HTTPSpan(
            id: id, runID: runID, method: "AI", url: question.model ?? question.provider ?? "", startedAt: Date(),
            duration: nil, status: nil, error: nil,
            requestHeaders: [:], requestBody: Self.truncated(masked(asked)),
            responseHeaders: [:], responseBody: nil, responseSize: 0
        )
        emit(.spanStarted(span))

        tasks[id] = Task {
            do {
                let answer = try await ai.answer(question)
                span.duration = Date().timeIntervalSince(span.startedAt)
                span.status = 200
                span.url = [answer.provider, answer.model].filter { !$0.isEmpty }.joined(separator: " · ")
                span.responseHeaders = ["input tokens": "\(answer.inputTokens)", "output tokens": "\(answer.outputTokens)"]
                span.responseBody = Self.truncated(masked(answer.text))
                span.responseSize = answer.text.utf8.count
                emit(.spanFinished(span))
                settle(id, value: [
                    "text": answer.text,
                    "provider": answer.provider,
                    "model": answer.model,
                    "inputTokens": answer.inputTokens,
                    "outputTokens": answer.outputTokens,
                ] as [String: Any])
            } catch {
                let message = Task.isCancelled ? "Run cancelled" : error.localizedDescription
                span.duration = Date().timeIntervalSince(span.startedAt)
                span.error = message
                emit(.spanFinished(span))
                settle(id, error: message)
            }
        }
    }

    /// `ai.image()`. The picture is saved with the run's files; the call is
    /// on record like `ai.ask()` and counts toward the same limit.
    func makePicture(runID: String, arguments: JSValue, callback: JSValue) {
        guard let id = register(callback) else { return }
        guard let ai else {
            return settle(id, error: "ai.image() is not available here.")
        }
        aiCalls += 1
        guard aiCalls <= maxAICalls else {
            return settle(id, error: "This run has already asked the AI \(maxAICalls) times, the most one run may. Raise the limit in Settings if it needs more.")
        }

        func text(_ name: String) -> String? {
            let value = arguments.forProperty(name)
            return value?.isString == true ? value?.toString() : nil
        }
        let request = AIPictureRequest(
            prompt: text("prompt") ?? "",
            provider: text("provider"),
            model: text("model"),
            size: text("size"),
            transparent: arguments.forProperty("transparent").toBool()
        )
        let wantedName = text("name") ?? ""
        let token = text("token") ?? ""

        var span = HTTPSpan(
            id: id, runID: runID, method: "AI", url: request.model ?? request.provider ?? "", startedAt: Date(),
            duration: nil, status: nil, error: nil,
            requestHeaders: [:], requestBody: Self.truncated(masked("Picture: \(request.prompt)")),
            responseHeaders: [:], responseBody: nil, responseSize: 0
        )
        emit(.spanStarted(span))

        tasks[id] = Task {
            do {
                let picture = try await ai.picture(request)
                // Named by what the bytes are, whatever was asked for.
                let type = picture.data.starts(with: [0xFF, 0xD8]) ? "jpg" : picture.data.starts(with: [0x52, 0x49, 0x46, 0x46]) ? "webp" : "png"
                let base = Self.fileName(wantedName.isEmpty ? "picture" : (wantedName as NSString).deletingPathExtension)
                let destination = Self.unused(outputDirectory.appending(path: "\(base).\(type)"))
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try picture.data.write(to: destination, options: .atomic)

                span.duration = Date().timeIntervalSince(span.startedAt)
                span.status = 200
                span.url = [picture.provider, picture.model].filter { !$0.isEmpty }.joined(separator: " · ")
                span.responseBody = "[picture saved as \(destination.lastPathComponent), \(picture.data.count.formatted(.byteCount(style: .file)))]"
                span.responseSize = picture.data.count
                emit(.spanFinished(span))

                var saved = SavedFile(id: UUID(), runID: runID, url: destination, name: nil, date: Date())
                if let label = pendingFileNames.removeValue(forKey: token)?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
                    saved.name = label
                }
                if !token.isEmpty { savedFiles[token] = saved }
                emit(.file(saved))
                settle(id, value: [
                    "name": destination.lastPathComponent,
                    "path": destination.path(percentEncoded: false),
                    "size": picture.data.count,
                ] as [String: Any])
            } catch {
                let message = Task.isCancelled ? "Run cancelled" : error.localizedDescription
                span.duration = Date().timeIntervalSince(span.startedAt)
                span.error = message
                emit(.spanFinished(span))
                settle(id, error: message)
            }
        }
    }
}
