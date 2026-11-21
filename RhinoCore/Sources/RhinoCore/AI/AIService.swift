import Foundation

/// What a request came back with, whichever provider answered.
struct ChatReply: Sendable, Equatable {
    var text = ""
    /// The model that answered, which can differ from the one asked for.
    var model = ""
    var inputTokens = 0
    var outputTokens = 0
}

/// One AI provider, ready to use: where it is, how to talk to it, the key and
/// the model.
public struct AIService: Sendable, Equatable {
    /// The wire format a provider speaks.
    public enum API: String, Codable, Sendable, CaseIterable {
        /// Anthropic's Messages API.
        case anthropic
        /// Chat completions, as OpenAI defined them.
        case openAI = "openai"
    }

    public static let anthropicBaseURL = ClaudeClient.defaultBaseURL
    public static let anthropicModel = ClaudeClient.defaultModel

    /// What the user calls it: "Anthropic", "OpenAI", "My server".
    public var name: String
    public var api: API
    /// For `.anthropic` the host ("https://api.anthropic.com"); for `.openAI`
    /// the address that `/chat/completions` hangs off ("https://api.openai.com/v1").
    public var baseURL: URL
    public var apiKey: String
    public var model: String
    /// False for servers that take no key, like a model running on this Mac.
    public var requiresKey: Bool

    public init(name: String, api: API, baseURL: URL, apiKey: String, model: String, requiresKey: Bool = true) {
        self.name = name
        self.api = api
        self.baseURL = baseURL
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.requiresKey = requiresKey
    }

    public static func anthropic(apiKey: String, baseURL: URL = anthropicBaseURL, model: String = anthropicModel) -> AIService {
        AIService(name: "Anthropic", api: .anthropic, baseURL: baseURL, apiKey: apiKey, model: model)
    }

    // MARK: - Asking

    /// Answers a script's question.
    public func answer(_ question: AIQuestion, session: URLSession = .shared) async throws -> AIAnswer {
        try await attempt {
            let model = try usableModel(question.model)
            let reply: ChatReply
            switch api {
            case .anthropic:
                let client = ClaudeClient(apiKey: apiKey, baseURL: baseURL, session: session)
                reply = try await client.send(try client.request(body: Self.anthropicBody(for: question, model: model)))
            case .openAI:
                let client = OpenAIClient(apiKey: apiKey, baseURL: baseURL, session: session)
                reply = try await client.complete(try Self.openAIBody(for: question, model: model, baseURL: baseURL))
            }
            guard !reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.Reason.empty }
            return AIAnswer(
                text: reply.text, provider: name, model: reply.model.isEmpty ? model : reply.model,
                inputTokens: reply.inputTokens, outputTokens: reply.outputTokens
            )
        }
    }

    /// Writes a long piece of text (a script) from fixed instructions and a
    /// request. `onText` gets the whole text so far each time more arrives.
    func write(system: String, prompt: String, session: URLSession, onText: (String) -> Void) async throws -> String {
        try await attempt {
            let model = try usableModel(nil)
            switch api {
            case .anthropic:
                let client = ClaudeClient(apiKey: apiKey, baseURL: baseURL, session: session)
                return try await client.send(try client.request(body: Self.anthropicWriterBody(system: system, prompt: prompt, model: model)), onText: onText).text
            case .openAI:
                let client = OpenAIClient(apiKey: apiKey, baseURL: baseURL, session: session)
                let body: [String: Any] = [
                    "model": model,
                    "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]],
                ]
                return try await client.stream(body, onText: onText).text
            }
        }
    }

    /// Makes a picture. Only providers that speak OpenAI's format can; the
    /// model is the one asked for, or the best picture model the key can use.
    public func picture(_ request: AIPictureRequest, session: URLSession = .shared) async throws -> AIPicture {
        try await attempt {
            try checkKey()
            guard api == .openAI else { throw AIError.Reason.unsupported("making pictures") }
            let client = OpenAIClient(apiKey: apiKey, baseURL: baseURL, session: session)
            var model = request.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if model.isEmpty {
                guard let found = Self.pictureModel(among: try await client.allModels()) else {
                    throw AIError.Reason.unsupported("making pictures: it lists no model for that")
                }
                model = found
            }
            var body: [String: Any] = ["model": model, "prompt": request.prompt, "n": 1, "size": request.size ?? "1024x1024"]
            if request.transparent { body["background"] = "transparent" }
            return AIPicture(data: try await client.picture(body), provider: name, model: model)
        }
    }

    /// The model to make pictures with when none was named: the newest of
    /// OpenAI's own, full-size before "mini", or failing that DALL·E.
    static func pictureModel(among models: [String]) -> String? {
        let own = models.filter { $0.hasPrefix("gpt-image") }.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        return own.first { !$0.contains("mini") } ?? own.first
            ?? models.filter { $0.hasPrefix("dall-e") }.sorted().last
            ?? models.first { $0.localizedCaseInsensitiveContains("image") && !$0.localizedCaseInsensitiveContains("embed") }
    }

    /// The models this key can use, for choosing one in settings. Getting an
    /// answer at all also shows that the address and key work.
    public func models(session: URLSession = .shared) async throws -> [String] {
        try await attempt {
            try checkKey()
            switch api {
            case .anthropic: return try await ClaudeClient(apiKey: apiKey, baseURL: baseURL, session: session).models()
            case .openAI: return try await OpenAIClient(apiKey: apiKey, baseURL: baseURL, session: session).models()
            }
        }
    }

    private func checkKey() throws {
        if requiresKey, apiKey.isEmpty { throw AIError.Reason.missingKey }
    }

    private func usableModel(_ requested: String?) throws -> String {
        try checkKey()
        let model = requested?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let chosen = model.isEmpty ? self.model : model
        if chosen.isEmpty { throw AIError.Reason.missingModel }
        return chosen
    }

    /// Runs `work`, naming this provider in whatever goes wrong.
    private func attempt<Value>(_ work: () async throws -> Value) async throws -> Value {
        do {
            return try await work()
        } catch let reason as AIError.Reason {
            throw AIError(reason, provider: name)
        }
    }

    // MARK: - Request bodies

    static func anthropicBody(for question: AIQuestion, model: String) throws -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            // Room for a long answer; thinking counts toward it too.
            "max_tokens": question.maxTokens ?? 16000,
            "messages": [["role": "user", "content": anthropicContent(for: question)]],
        ]
        if let system = question.system, !system.isEmpty {
            body["system"] = system
        }
        // Thinking and effort stay at the model's defaults unless the script
        // chose an effort: not every model takes the same settings.
        var output: [String: Any] = [:]
        if let effort = question.effort {
            output["effort"] = effort
        }
        if let schema = question.schema {
            // With a format the answer is guaranteed to be JSON matching the schema.
            output["format"] = ["type": "json_schema", "schema": try JSONSerialization.jsonObject(with: Data(schema.utf8))]
        }
        if !output.isEmpty {
            body["output_config"] = output
        }
        if model == anthropicModel {
            // If a safety classifier declines the request by mistake, the API
            // retries it on the model Anthropic recommends instead of failing.
            body["fallbacks"] = "default"
        }
        return body
    }

    /// The prompt alone, or the files followed by the prompt.
    static func anthropicContent(for question: AIQuestion) -> Any {
        guard !question.attachments.isEmpty else { return question.prompt }
        var blocks: [[String: Any]] = question.attachments.map { file in
            switch file.kind {
            case .image:
                ["type": "image", "source": ["type": "base64", "media_type": file.mediaType, "data": file.base64]]
            case .pdf:
                ["type": "document", "source": ["type": "base64", "media_type": file.mediaType, "data": file.base64]]
            case .text:
                ["type": "text", "text": file.quoted]
            }
        }
        blocks.append(["type": "text", "text": question.prompt])
        return blocks
    }

    static func openAIContent(for question: AIQuestion) -> Any {
        guard !question.attachments.isEmpty else { return question.prompt }
        var parts: [[String: Any]] = question.attachments.map { file in
            switch file.kind {
            case .image:
                ["type": "image_url", "image_url": ["url": file.dataURL]]
            case .pdf:
                ["type": "file", "file": ["filename": file.name, "file_data": file.dataURL]]
            case .text:
                ["type": "text", "text": file.quoted]
            }
        }
        parts.append(["type": "text", "text": question.prompt])
        return parts
    }

    static func anthropicWriterBody(system: String, prompt: String, model: String) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            // The instructions are identical for every job, so they are cached.
            "system": [[
                "type": "text",
                "text": system,
                "cache_control": ["type": "ephemeral"],
            ]],
            "messages": [["role": "user", "content": prompt]],
        ]
        if model == anthropicModel {
            // Generous, because thinking counts toward it and a cut-off script is useless.
            body["max_tokens"] = 64000
            body["thinking"] = ["type": "adaptive"]
            // This model's default, set explicitly: enough to get a small,
            // fully specified script right without making the user wait.
            body["output_config"] = ["effort": "medium"]
            body["fallbacks"] = "default"
        } else {
            // Another model the user chose: only what every Claude model accepts.
            body["max_tokens"] = 32000
        }
        return body
    }

    static func openAIBody(for question: AIQuestion, model: String, baseURL: URL) throws -> [String: Any] {
        var messages: [[String: Any]] = []
        if let system = question.system, !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }
        messages.append(["role": "user", "content": openAIContent(for: question)])

        var body: [String: Any] = ["model": model, "messages": messages]
        if let limit = question.maxTokens {
            // OpenAI renamed the field and its newer models refuse the old
            // name; the servers that copied the format still know only the old one.
            body[baseURL.host() == "api.openai.com" ? "max_completion_tokens" : "max_tokens"] = limit
        }
        if let effort = question.effort {
            body["reasoning_effort"] = effort
        }
        if let schema = question.schema {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": [
                    "name": "answer",
                    "strict": true,
                    "schema": try JSONSerialization.jsonObject(with: Data(schema.utf8)),
                ] as [String: Any],
            ] as [String: Any]
        }
        return body
    }
}
