import Foundation

extension StubProtocol {
    /// A stand-in for an OpenAI-style `POST …/images/generations`.
    func respondAsImageGeneration(to url: URL) {
        // A stand-in picture: the bytes say which model and size were asked for.
        let sent = request.httpBodyStream.map(Self.read) ?? request.httpBody ?? Data()
        let asked = (try? JSONSerialization.jsonObject(with: sent)) as? [String: Any] ?? [:]
        let picture = Data("\u{89}PNG \(asked["model"] ?? "") \(asked["size"] ?? "") \(asked["background"] ?? "opaque") \(asked["prompt"] ?? "")".utf8)
        let answer = try! JSONSerialization.data(withJSONObject: ["data": [["b64_json": picture.base64EncodedString()]]])
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// A stand-in for `GET …/models`, for both kinds of provider.
    func respondAsModelList(to url: URL) {
        // Anthropic's list when asked the Anthropic way, otherwise an OpenAI-style one.
        let list = request.value(forHTTPHeaderField: "x-api-key") != nil
            ? #"{"data":[{"id":"claude-opus-5-5"},{"id":"claude-haiku-5-5"}],"has_more":false}"#
            : #"{"object":"list","data":[{"id":"zeta-chat"},{"id":"text-embedding-test"},{"id":"models/gemini-test"},{"id":"alpha-chat"},{"id":"gpt-image-1"},{"id":"gpt-image-2-mini"},{"id":"gpt-image-2"}]}"#
        let bad = request.value(forHTTPHeaderField: "Authorization") == "Bearer bad-key"
        let response = HTTPURLResponse(url: url, statusCode: bad ? 401 : 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((bad ? #"{"error":{"message":"Incorrect API key provided","type":"invalid_request_error"}}"# : list).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
