import Foundation

extension StubProtocol {
    /// A stand-in for `POST /v1/messages` with streaming. What it answers
    /// depends on a keyword in the user message, and by default the "script"
    /// it writes reports what the request looked like.
    func respondAsMessagesAPI(to url: URL) {
        let sent = request.httpBodyStream.map(Self.read) ?? request.httpBody ?? Data()
        let body = (try? JSONSerialization.jsonObject(with: sent)) as? [String: Any] ?? [:]
        let system = (body["system"] as? [[String: Any]])?.first ?? [:]
        let user = ((body["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""

        func finish(status: Int, type: String, body: String) {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        func event(_ object: [String: Any]) -> String {
            let json = String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            return "event: \(object["type"] as? String ?? "")\ndata: \(json)\n\n"
        }
        func stream(text pieces: [String], stopReason: String) -> String {
            var events = event(["type": "message_start", "message": ["id": "msg_test", "model": body["model"] ?? "", "usage": ["input_tokens": 42]]])
            // Thinking comes first and must not end up in the script.
            events += event(["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": ""]])
            events += event(["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": "SECRET THOUGHTS"]])
            events += event(["type": "content_block_stop", "index": 0])
            events += event(["type": "ping"])
            events += event(["type": "content_block_start", "index": 1, "content_block": ["type": "text", "text": ""]])
            for piece in pieces {
                events += event(["type": "content_block_delta", "index": 1, "delta": ["type": "text_delta", "text": piece]])
            }
            events += event(["type": "content_block_stop", "index": 1])
            events += event(["type": "message_delta", "delta": ["stop_reason": stopReason], "usage": ["output_tokens": 10]])
            events += event(["type": "message_stop"])
            return events
        }

        if request.value(forHTTPHeaderField: "x-api-key") == "bad-key" {
            return finish(status: 401, type: "application/json", body: #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#)
        }
        if user.contains("REFUSE") {
            return finish(status: 200, type: "text/event-stream", body: stream(text: [], stopReason: "refusal"))
        }
        if user.contains("TOO LONG") {
            return finish(status: 200, type: "text/event-stream", body: stream(text: ["// @name Half\nconst a ="], stopReason: "max_tokens"))
        }
        if user.contains("OVERLOADED") {
            let failure = event(["type": "error", "error": ["type": "overloaded_error", "message": "Overloaded"]])
            return finish(status: 200, type: "text/event-stream", body: failure)
        }
        // `ai.ask()` with a shape: answer with data that fits the usual test shapes.
        if let format = (body["output_config"] as? [String: Any])?["format"] as? [String: Any] {
            let properties = (format["schema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
            let answer = properties["value"] != nil ? #"{"value":["red","green"]}"# : #"{"mood":"happy","score":4}"#
            return finish(status: 200, type: "text/event-stream", body: stream(text: [String(answer.prefix(9)), String(answer.dropFirst(9))], stopReason: "end_turn"))
        }
        if user.contains("FENCED") {
            let pieces = ["\n``", "`js\n// @name Fenced\n", "output.json(1 + 1)", ".name(\"Two\");\n``", "`\n\n"]
            return finish(status: 200, type: "text/event-stream", body: stream(text: pieces, stopReason: "end_turn"))
        }

        let facts: [String: Any] = [
            "model": body["model"] ?? "",
            "stream": body["stream"] ?? false,
            "maxTokens": body["max_tokens"] ?? 0,
            "thinking": (body["thinking"] as? [String: Any])?["type"] ?? "",
            "effort": (body["output_config"] as? [String: Any])?["effort"] ?? "",
            "fallbacks": body["fallbacks"] ?? "",
            "version": request.value(forHTTPHeaderField: "anthropic-version") ?? "",
            "beta": request.value(forHTTPHeaderField: "anthropic-beta") ?? "",
            "cached": ((system["cache_control"] as? [String: Any])?["type"] as? String) == "ephemeral",
            "systemHasAPI": (system["text"] as? String)?.contains("declare const input") == true,
            "systemHasExample": (system["text"] as? String)?.contains("// @name Weather outlook") == true,
            "user": user,
            "plainSystem": body["system"] as? String ?? "",
        ]
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys]), as: UTF8.self)
        // `ai.ask()` wants the facts themselves, not a script that reports them.
        if user.contains("ECHO") {
            return finish(status: 200, type: "text/event-stream", body: stream(text: [json], stopReason: "end_turn"))
        }
        let script = "// @name Echo\n// @description Reports the request\n\noutput.json(\(json)).name(\"Request\");\n"
        // Split mid-word, the way real deltas arrive.
        let middle = script.index(script.startIndex, offsetBy: script.count / 2)
        finish(status: 200, type: "text/event-stream", body: stream(text: [String(script[..<middle]), String(script[middle...])], stopReason: "end_turn"))
    }
}
