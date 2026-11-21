import Foundation

/// Anthropic's Messages API, answered as a stream.
struct ClaudeClient: Sendable {
    static let defaultModel = "claude-opus-5-5"
    static let defaultBaseURL = URL(string: "https://api.anthropic.com")!

    let apiKey: String
    let baseURL: URL
    let session: URLSession

    init(apiKey: String, baseURL: URL = ClaudeClient.defaultBaseURL, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
    }

    private func request(path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.timeoutInterval = 600
        if !apiKey.isEmpty { request.setValue(apiKey, forHTTPHeaderField: "x-api-key") }
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        return request
    }

    /// A streaming request with `body` as its JSON. `stream` is set here.
    func request(body: [String: Any]) throws -> URLRequest {
        var request = request(path: "v1/messages")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if body["fallbacks"] != nil {
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }

        var body = body
        // Streamed, so a long answer cannot run into a request timeout.
        body["stream"] = true
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Sends a request and collects the answer. `onText` gets the whole text
    /// so far each time more arrives.
    func send(_ request: URLRequest, onText: (String) -> Void = { _ in }) async throws -> ChatReply {
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard status == 200 else {
            var body = Data()
            for try await byte in bytes where body.count < 64 * 1024 {
                body.append(byte)
            }
            throw Self.failure(status: status, body: body)
        }

        var reply = ChatReply()
        var stopReason: String?
        for try await line in bytes.lines {
            // Server-sent events: only the `data:` lines carry anything.
            guard line.hasPrefix("data:"),
                  let event = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any],
                  let type = event["type"] as? String else { continue }

            switch type {
            case "message_start":
                let message = event["message"] as? [String: Any]
                reply.model = message?["model"] as? String ?? ""
                reply.inputTokens = Self.tokens("input_tokens", in: message?["usage"])
            case "content_block_delta":
                // Thinking arrives as other delta types and is not part of the answer.
                if let delta = event["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta",
                   let piece = delta["text"] as? String {
                    reply.text += piece
                    onText(reply.text)
                }
            case "message_delta":
                if let delta = event["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                    stopReason = reason
                }
                if event["usage"] != nil {
                    reply.outputTokens = Self.tokens("output_tokens", in: event["usage"])
                }
            case "error":
                let error = event["error"] as? [String: Any]
                throw AIError.Reason.api(
                    status: status,
                    kind: error?["type"] as? String ?? "error",
                    message: error?["message"] as? String ?? "The response ended with an error."
                )
            default:
                break
            }
        }

        // A refusal is a successful response, so it has to be checked for.
        switch stopReason {
        case "refusal": throw AIError.Reason.refused
        case "max_tokens": throw AIError.Reason.truncated
        default: return reply
        }
    }

    /// The ids of the models the key can use, newest first as the API lists them.
    func models() async throws -> [String] {
        var request = request(path: "v1/models")
        request.url?.append(queryItems: [URLQueryItem(name: "limit", value: "1000")])
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Self.failure(status: status, body: data) }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }

    private static func tokens(_ key: String, in usage: Any?) -> Int {
        ((usage as? [String: Any])?[key] as? NSNumber)?.intValue ?? 0
    }

    private static func failure(status: Int, body: Data) -> AIError.Reason {
        let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let error = json?["error"] as? [String: Any]
        return .api(
            status: status,
            kind: error?["type"] as? String ?? "error",
            message: error?["message"] as? String ?? HTTPURLResponse.localizedString(forStatusCode: status)
        )
    }
}
