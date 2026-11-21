import Foundation

/// Serves canned responses so tests never touch the network.
///
/// The AI stand-ins live in extensions: `StubProtocol+Messages.swift`,
/// `StubProtocol+ChatCompletions.swift` and `StubProtocol+ModelsAndImages.swift`.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }

        if url.path == "/v1/messages" {
            return respondAsMessagesAPI(to: url)
        }
        if url.path.hasSuffix("/chat/completions") {
            return respondAsChatCompletions(to: url)
        }
        if url.path.hasSuffix("/images/generations") {
            return respondAsImageGeneration(to: url)
        }
        if url.path.hasSuffix("/models") {
            return respondAsModelList(to: url)
        }
        respondAsPlainHTTP(to: url)
    }

    /// The plain endpoints scripts call with `get()`, `post()` and friends.
    /// Any path not listed answers 500.
    private func respondAsPlainHTTP(to url: URL) {
        var status = 200
        var body = Data()
        var headers = ["Content-Type": "application/json"]

        switch url.path {
        case "/users":
            body = Data(#"[{"id":1,"name":"Ada"},{"id":2,"name":"Linus"}]"#.utf8)
        case "/echo":
            let sent = request.httpBodyStream.map(Self.read) ?? request.httpBody ?? Data()
            let payload: [String: Any] = [
                "method": request.httpMethod ?? "",
                "query": url.query() ?? "",
                "contentType": request.value(forHTTPHeaderField: "Content-Type") ?? "",
                "body": String(decoding: sent, as: UTF8.self),
            ]
            body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        case "/text":
            headers = ["Content-Type": "text/plain"]
            body = Data("plain words".utf8)
        default:
            status = 500
            body = Data(#"{"error":"boom"}"#.utf8)
        }

        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// Reads a request body that arrives as a stream, as `URLSession` hands it over.
    static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
