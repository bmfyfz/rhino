import Foundation

extension StubProtocol {
    /// A stand-in for an OpenAI-style `POST …/chat/completions`, streamed or whole.
    func respondAsChatCompletions(to url: URL) {
        let sent = request.httpBodyStream.map(Self.read) ?? request.httpBody ?? Data()
        let body = (try? JSONSerialization.jsonObject(with: sent)) as? [String: Any] ?? [:]
        let messages = body["messages"] as? [[String: Any]] ?? []
        let user = messages.last?["content"] as? String ?? ""
        let system = messages.first { $0["role"] as? String == "system" }?["content"] as? String ?? ""
        let streams = body["stream"] as? Bool == true

        func finish(status: Int, type: String, body: String) {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        func text(_ object: [String: Any]) -> String {
            String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        func answer(_ content: String, finishReason: String = "stop") {
            let model = "\(body["model"] ?? "")-served"
            if streams {
                let middle = content.index(content.startIndex, offsetBy: content.count / 2)
                var events = ""
                for piece in [String(content[..<middle]), String(content[middle...])] {
                    events += "data: " + text(["model": model, "choices": [["index": 0, "delta": ["content": piece]]]]) + "\n\n"
                }
                events += "data: " + text(["model": model, "choices": [["index": 0, "delta": [:] as [String: Any], "finish_reason": finishReason]]]) + "\n\n"
                events += "data: [DONE]\n\n"
                finish(status: 200, type: "text/event-stream", body: events)
            } else {
                finish(status: 200, type: "application/json", body: text([
                    "model": model,
                    "choices": [["index": 0, "message": ["role": "assistant", "content": content], "finish_reason": finishReason]],
                    "usage": ["prompt_tokens": 7, "completion_tokens": 3],
                ]))
            }
        }

        if request.value(forHTTPHeaderField: "Authorization") == "Bearer bad-key" {
            return finish(status: 401, type: "application/json", body: #"{"error":{"message":"Incorrect API key provided","type":"invalid_request_error","code":"invalid_api_key"}}"#)
        }
        if user.contains("BUSY") {
            return finish(status: 429, type: "application/json", body: #"{"error":{"message":"Slow down","type":"requests"}}"#)
        }
        if user.contains("TOO LONG") {
            return answer("// @name Half\nconst a =", finishReason: "length")
        }
        if user.contains("REFUSE") {
            return answer("", finishReason: "content_filter")
        }
        if body["response_format"] != nil {
            // Fenced, the way some models answer even when asked for bare JSON.
            return answer("```json\n{\"mood\":\"happy\",\"score\":4}\n```")
        }

        let format = (body["response_format"] as? [String: Any])?["type"] as? String ?? ""
        let facts: [String: Any] = [
            "model": body["model"] ?? "",
            "stream": streams,
            "authorization": request.value(forHTTPHeaderField: "Authorization") ?? "",
            "path": url.path,
            "host": url.host() ?? "",
            "system": String(system.prefix(60)),
            "systemHasAPI": system.contains("declare const input"),
            "user": user,
            "maxTokens": body["max_tokens"] ?? 0,
            "maxCompletionTokens": body["max_completion_tokens"] ?? 0,
            "effort": body["reasoning_effort"] ?? "",
            "format": format,
        ]
        let json = text(facts)
        if user.contains("ECHO") { return answer(json) }
        answer("// @name Echo\n// @description Reports the request\n\noutput.json(\(json)).name(\"Request\");\n")
    }
}
