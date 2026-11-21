import Foundation

/// Chat completions as OpenAI defined them. Google, xAI, OpenRouter, Ollama
/// and most other providers offer the same format at their own address.
struct OpenAIClient: Sendable {
    let apiKey: String
    /// What `/chat/completions` and `/models` hang off, e.g. "https://api.openai.com/v1".
    let baseURL: URL
    let session: URLSession

    private func request(path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.timeoutInterval = 600
        // A server on this Mac usually takes no key at all.
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func post(_ body: [String: Any]) throws -> URLRequest {
        var request = request(path: "chat/completions")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// One request, one whole answer. Used for `ai.ask()`: unlike a stream,
    /// every server reports the tokens used this way.
    func complete(_ body: [String: Any]) async throws -> ChatReply {
        let (data, response) = try await session.data(for: try post(body))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Self.failure(status: status, body: data) }

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let choice = (json["choices"] as? [[String: Any]])?.first
        let message = choice?["message"] as? [String: Any]
        let usage = json["usage"] as? [String: Any]
        let reply = ChatReply(
            text: message?["content"] as? String ?? "",
            model: json["model"] as? String ?? "",
            inputTokens: (usage?["prompt_tokens"] as? NSNumber)?.intValue ?? 0,
            outputTokens: (usage?["completion_tokens"] as? NSNumber)?.intValue ?? 0
        )
        // OpenAI puts a model's refusal in its own field, with no content.
        if reply.text.isEmpty, message?["refusal"] is String { throw AIError.Reason.refused }
        try Self.check(finishReason: choice?["finish_reason"] as? String)
        return reply
    }

    /// The answer as it is written. `onText` gets the whole text so far each
    /// time more arrives.
    func stream(_ body: [String: Any], onText: (String) -> Void) async throws -> ChatReply {
        var body = body
        body["stream"] = true
        let (bytes, response) = try await session.bytes(for: try post(body))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard status == 200 else {
            var data = Data()
            for try await byte in bytes where data.count < 64 * 1024 {
                data.append(byte)
            }
            throw Self.failure(status: status, body: data)
        }

        var reply = ChatReply()
        var finishReason: String?
        for try await line in bytes.lines {
            // Server-sent events; the stream ends with a literal "[DONE]".
            guard line.hasPrefix("data:"),
                  let event = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any] else { continue }

            if let error = event["error"] as? [String: Any] {
                throw AIError.Reason.api(
                    status: status,
                    kind: Self.kind(status: status, type: error["type"] as? String),
                    message: error["message"] as? String ?? "The response ended with an error."
                )
            }
            if let model = event["model"] as? String, reply.model.isEmpty { reply.model = model }
            guard let choice = (event["choices"] as? [[String: Any]])?.first else { continue }
            if let piece = (choice["delta"] as? [String: Any])?["content"] as? String, !piece.isEmpty {
                reply.text += piece
                onText(reply.text)
            }
            if let reason = choice["finish_reason"] as? String { finishReason = reason }
        }
        try Self.check(finishReason: finishReason)
        return reply
    }

    /// The ids of the models the key can use that can hold a conversation.
    func models() async throws -> [String] {
        // Providers list everything they host; these are not for chatting.
        let others = ["embed", "tts", "whisper", "dall-e", "moderation", "transcribe", "realtime", "image", "audio", "imagen", "veo", "aqa"]
        return try await allModels()
            .filter { id in !others.contains { id.localizedCaseInsensitiveContains($0) } }
            .sorted()
    }

    /// The id of every model the key can use, whatever it is for.
    func allModels() async throws -> [String] {
        var request = request(path: "models")
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Self.failure(status: status, body: data) }

        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["data"] as? [[String: Any]] ?? [])
            .compactMap { $0["id"] as? String }
            // Google lists "models/gemini-…" but takes the plain name.
            .map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }
    }

    /// One picture, as the bytes of an image file. Newer models answer with
    /// the picture itself; older ones with an address to fetch it from.
    func picture(_ body: [String: Any]) async throws -> Data {
        var request = request(path: "images/generations")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Self.failure(status: status, body: data) }

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let first = (json?["data"] as? [[String: Any]])?.first
        if let encoded = first?["b64_json"] as? String, let picture = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) {
            return picture
        }
        if let address = (first?["url"] as? String).flatMap(URL.init(string:)) {
            let (picture, fetched) = try await session.data(from: address)
            if (fetched as? HTTPURLResponse)?.statusCode == 200 { return picture }
        }
        throw AIError.Reason.empty
    }

    private static func check(finishReason: String?) throws {
        switch finishReason {
        case "length": throw AIError.Reason.truncated
        case "content_filter": throw AIError.Reason.refused
        default: break
        }
    }

    private static func failure(status: Int, body: Data) -> AIError.Reason {
        // Usually {"error": {...}}; Google wraps that in an array.
        let parsed = try? JSONSerialization.jsonObject(with: body)
        let json = parsed as? [String: Any] ?? (parsed as? [[String: Any]])?.first
        let error = json?["error"] as? [String: Any]
        return .api(
            status: status,
            kind: kind(status: status, type: error?["type"] as? String),
            message: error?["message"] as? String ?? HTTPURLResponse.localizedString(forStatusCode: status)
        )
    }

    /// Providers name their errors differently; the status says the same
    /// thing everywhere.
    private static func kind(status: Int, type: String?) -> String {
        switch status {
        case 401: "authentication_error"
        case 403: "permission_error"
        case 402: "billing_error"
        case 429: "rate_limit_error"
        case 503, 529: "overloaded_error"
        default: type ?? "error"
        }
    }
}
