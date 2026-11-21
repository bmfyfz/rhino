import Foundation
import JavaScriptCore
import UniformTypeIdentifiers

// `get`, `post` and the other HTTP globals, `upload()` and `download()`.
extension Execution {
    // MARK: - Requests

    func http(runID: String, arguments: JSValue, callback: JSValue) {
        guard let id = register(callback) else { return }

        let method = arguments.forProperty("method").toString() ?? "GET"
        let urlString = arguments.forProperty("url").toString() ?? ""
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return settle(id, error: "Invalid URL: \(urlString)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        var headers: [String: String] = [:]
        for (key, value) in arguments.forProperty("headers").toDictionary() ?? [:] {
            headers["\(key)"] = "\(value)"
        }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }

        var body: String?
        if let value = arguments.forProperty("body"), value.isString {
            body = value.toString()
            request.httpBody = body?.data(using: .utf8)
        }
        // A file as the body, or a form with fields and files. What is
        // recorded says what was sent, not the bytes themselves.
        do {
            if let value = arguments.forProperty("bodyFile"), value.isString {
                let file = resolve(path: value.toString())
                let data = try Self.contents(of: file)
                request.httpBody = data
                if !headers.keys.contains(where: { $0.lowercased() == "content-type" }) {
                    headers["Content-Type"] = Self.mediaType(of: file)
                    request.setValue(headers["Content-Type"], forHTTPHeaderField: "Content-Type")
                }
                body = "[file \(file.lastPathComponent), \(data.count.formatted(.byteCount(style: .file)))]"
            } else if let parts = arguments.forProperty("multipart").toArray() as? [[String: Any]], !parts.isEmpty {
                let boundary = "rhino-\(UUID().uuidString)"
                var data = Data()
                var described: [String] = []
                for part in parts {
                    let name = "\(part["name"] ?? "")".replacing("\"", with: "%22")
                    data.append(Data("--\(boundary)\r\n".utf8))
                    if let path = part["path"] as? String {
                        let file = resolve(path: path)
                        let contents = try Self.contents(of: file)
                        let filename = (part["filename"] as? String ?? file.lastPathComponent).replacing("\"", with: "%22")
                        data.append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(Self.mediaType(of: file))\r\n\r\n".utf8))
                        data.append(contents)
                        described.append("\(name): [file \(filename), \(contents.count.formatted(.byteCount(style: .file)))]")
                    } else {
                        let value = "\(part["value"] ?? "")"
                        data.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)".utf8))
                        described.append("\(name): \(value)")
                    }
                    data.append(Data("\r\n".utf8))
                }
                data.append(Data("--\(boundary)--\r\n".utf8))
                request.httpBody = data
                headers["Content-Type"] = "multipart/form-data; boundary=\(boundary)"
                request.setValue(headers["Content-Type"], forHTTPHeaderField: "Content-Type")
                body = described.joined(separator: "\n")
            }
        } catch {
            return settle(id, error: error.localizedDescription)
        }
        let timeout = arguments.forProperty("timeout").toDouble()
        if timeout > 0 { request.timeoutInterval = timeout / 1000 }

        // What is recorded for the user to look at never shows a secret; the
        // request itself is of course sent as written.
        var span = HTTPSpan(
            id: id, runID: runID, method: method, url: masked(urlString), startedAt: Date(),
            duration: nil, status: nil, error: nil,
            requestHeaders: masker.mask(headers: headers), requestBody: body.map { Self.truncated(masked($0)) },
            responseHeaders: [:], responseBody: nil, responseSize: 0
        )
        emit(.spanStarted(span))

        let session = session
        tasks[id] = Task {
            do {
                let (data, response) = try await session.data(for: request)
                let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                var responseHeaders: [String: String] = [:]
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                for (key, value) in (response as? HTTPURLResponse)?.allHeaderFields ?? [:] {
                    responseHeaders["\(key)".lowercased()] = "\(value)"
                }
                span.duration = Date().timeIntervalSince(span.startedAt)
                span.status = status
                span.responseHeaders = masker.mask(headers: responseHeaders)
                span.responseBody = Self.truncated(masked(text))
                span.responseSize = data.count
                emit(.spanFinished(span))
                settle(id, value: [
                    "status": status,
                    "headers": responseHeaders,
                    "text": text,
                    "url": response.url?.absoluteString ?? urlString,
                ] as [String: Any])
            } catch {
                let message = Task.isCancelled ? "Run cancelled" : error.localizedDescription
                span.duration = Date().timeIntervalSince(span.startedAt)
                span.error = message
                emit(.spanFinished(span))
                settle(id, error: "\(method) \(urlString) failed: \(message)")
            }
        }
    }

    // MARK: - Downloads

    /// `download()`: a GET whose answer is kept as a file instead of read as text.
    func download(runID: String, arguments: JSValue, callback: JSValue) {
        guard let id = register(callback) else { return }

        let urlString = arguments.forProperty("url").toString() ?? ""
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return settle(id, error: "Invalid URL: \(urlString)")
        }
        var request = URLRequest(url: url)
        var headers: [String: String] = [:]
        for (key, value) in arguments.forProperty("headers").toDictionary() ?? [:] {
            headers["\(key)"] = "\(value)"
            request.setValue("\(value)", forHTTPHeaderField: "\(key)")
        }
        let timeout = arguments.forProperty("timeout").toDouble()
        if timeout > 0 { request.timeoutInterval = timeout / 1000 }
        let wantedName = arguments.forProperty("name").flatMap { $0.isString ? $0.toString() : nil } ?? ""
        let token = arguments.forProperty("token").toString() ?? ""

        var span = HTTPSpan(
            id: id, runID: runID, method: "GET", url: masked(urlString), startedAt: Date(),
            duration: nil, status: nil, error: nil,
            requestHeaders: masker.mask(headers: headers), requestBody: nil,
            responseHeaders: [:], responseBody: nil, responseSize: 0
        )
        emit(.spanStarted(span))

        let session = session
        tasks[id] = Task {
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                var responseHeaders: [String: String] = [:]
                for (key, value) in (response as? HTTPURLResponse)?.allHeaderFields ?? [:] {
                    responseHeaders["\(key)".lowercased()] = "\(value)"
                }
                span.duration = Date().timeIntervalSince(span.startedAt)
                span.status = status
                span.responseHeaders = masker.mask(headers: responseHeaders)
                span.responseSize = data.count
                guard (200..<300).contains(status) else {
                    span.responseBody = String(data: data.prefix(2000), encoding: .utf8).map(masked)
                    emit(.spanFinished(span))
                    return settle(id, error: "GET \(urlString) failed with status \(status)")
                }

                // The name asked for, else the one the server suggests, which
                // Foundation works out from its headers and the address.
                let name = Self.fileName(wantedName.isEmpty ? response.suggestedFilename ?? "" : wantedName)
                let destination = Self.unused(outputDirectory.appending(path: name))
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
                span.responseBody = "[saved as \(destination.lastPathComponent), \(data.count.formatted(.byteCount(style: .file)))]"
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
                    "size": data.count,
                ] as [String: Any])
            } catch {
                let message = Task.isCancelled ? "Run cancelled" : error.localizedDescription
                span.duration = Date().timeIntervalSince(span.startedAt)
                span.error = message
                emit(.spanFinished(span))
                settle(id, error: "GET \(urlString) failed: \(message)")
            }
        }
    }

    /// A name safe to use for a file in the run's folder.
    static func fileName(_ suggested: String) -> String {
        let name = (suggested as NSString).lastPathComponent
            .replacing(/[\/:\x00-\x1f]/, with: "-")
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty || name == "." || name == ".." ? "download" : name
    }

    /// `url`, or the same with a number added if a file is already there.
    static func unused(_ url: URL) -> URL {
        var candidate = url
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            candidate = url.deletingLastPathComponent().appending(path: ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }

    static func contents(of file: URL) throws -> Data {
        do {
            return try Data(contentsOf: file)
        } catch {
            throw RunError(message: "Cannot read \(file.path(percentEncoded: false)): \(error.localizedDescription)")
        }
    }

    static func mediaType(of file: URL) -> String {
        UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}
