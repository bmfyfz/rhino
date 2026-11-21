import Foundation
import JavaScriptCore

// `read`, `write`, `file` and `sleep`.
extension Execution {
    // MARK: - Files

    /// Absolute and `~` paths are used as they are; relative paths live in the
    /// run's output directory.
    func resolve(path: String?) -> URL {
        let expanded = NSString(string: path ?? "").expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(filePath: expanded) }
        return outputDirectory.appending(path: expanded)
    }

    func readFile(arguments: JSValue, callback: JSValue) {
        guard let id = register(callback) else { return }
        let url = resolve(path: arguments.forProperty("path").toString())
        do {
            let data = try Data(contentsOf: url)
            settle(id, value: String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self))
        } catch {
            settle(id, error: "Cannot read \(url.path(percentEncoded: false)): \(error.localizedDescription)")
        }
    }

    /// Whether a place is inside one of the folders scripts must not write
    /// into. A script that could rewrite other scripts, or the functions
    /// they all share, could make them do anything on their next run. Links
    /// are followed first, so a shortcut into such a folder does not get round it.
    func isProtected(_ url: URL) -> Bool {
        func canonical(_ url: URL) -> String {
            let folder = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            return folder.appending(path: url.lastPathComponent).path(percentEncoded: false)
        }
        func contains(_ folder: URL, _ path: String) -> Bool {
            let base = folder.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
            return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
        }
        let path = canonical(url)
        // Where runs keep their own files is the one place inside that is always fine.
        guard !contains(outputDirectory.deletingLastPathComponent(), path) else { return false }
        return protectedDirectories.contains { contains($0, path) }
    }

    func writeFile(runID: String, arguments: JSValue, callback: JSValue) {
        guard let id = register(callback) else { return }
        let url = resolve(path: arguments.forProperty("path").toString())
        guard !isProtected(url) else {
            return settle(id, error: "Scripts cannot write into the app's own folders (\(url.deletingLastPathComponent().path(percentEncoded: false))). Choose another place.")
        }
        let text = arguments.forProperty("text").toString() ?? ""
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
            let saved = SavedFile(id: UUID(), runID: runID, url: url, name: nil, date: Date())
            // Only `output.file()` sends a token, which is what lets it be named afterwards.
            if let token = arguments.forProperty("token").toString(), !token.isEmpty, token != "undefined" {
                savedFiles[token] = saved
            }
            emit(.file(saved))
            settle(id, value: url.path(percentEncoded: false))
        } catch {
            settle(id, error: "Cannot write \(url.path(percentEncoded: false)): \(error.localizedDescription)")
        }
    }

    // MARK: - Shell

    /// `shell()`: a command run with zsh. It is on record like an HTTP call:
    /// the command, how it ended, how long it took and what it printed.
    func shell(runID: String, arguments: JSValue, callback: JSValue) {
        guard let id = register(callback) else { return }
        let command = arguments.forProperty("command").toString() ?? ""
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return settle(id, error: "shell() needs a command, for example shell(\"ls ~/Downloads\").")
        }
        let directory = arguments.forProperty("cwd").flatMap { $0.isString ? resolve(path: $0.toString()) : nil }
        let input = arguments.forProperty("input").flatMap { $0.isString ? $0.toString() : nil }
        let timeout = arguments.forProperty("timeout").toDouble()
        var environment: [String: String] = [:]
        for (key, value) in arguments.forProperty("env").toDictionary() ?? [:] {
            environment["\(key)"] = "\(value)"
        }

        var span = HTTPSpan(
            id: id, runID: runID, method: "SH", url: masked(command), startedAt: Date(),
            duration: nil, status: nil, error: nil,
            requestHeaders: [:], requestBody: input.map { Self.truncated(masked($0)) },
            responseHeaders: [:], responseBody: nil, responseSize: 0
        )
        emit(.spanStarted(span))

        tasks[id] = Task {
            do {
                let outcome = try await ShellCommand.run(
                    command, directory: directory, environment: environment, input: input,
                    timeout: timeout > 0 ? timeout / 1000 : nil
                )
                span.duration = Date().timeIntervalSince(span.startedAt)
                // Shown the way a call is: fine, or failed.
                span.status = outcome.code == 0 ? 200 : 500
                span.responseHeaders = ["exit code": "\(outcome.code)"]
                let printed = [outcome.stdout, outcome.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
                span.responseBody = Self.truncated(masked(printed))
                span.responseSize = outcome.stdout.utf8.count + outcome.stderr.utf8.count
                if outcome.timedOut { span.error = "Stopped after \((timeout / 1000).formatted()) s" }
                emit(.spanFinished(span))
                settle(id, value: [
                    "stdout": outcome.stdout,
                    "stderr": outcome.stderr,
                    "code": Int(outcome.code),
                    "timedOut": outcome.timedOut,
                ] as [String: Any])
            } catch {
                let message = Task.isCancelled ? "Run cancelled" : error.localizedDescription
                span.duration = Date().timeIntervalSince(span.startedAt)
                span.error = message
                emit(.spanFinished(span))
                settle(id, error: "shell() could not run the command: \(message)")
            }
        }
    }

    // MARK: - Sleep

    func sleep(milliseconds: Double, callback: JSValue) {
        guard let id = register(callback) else { return }
        // Clamped: a huge number would overflow, and nobody means to wait longer than a week.
        let duration = Duration.milliseconds(milliseconds.isNaN ? 0 : min(max(0, milliseconds), 7 * 86_400_000))
        tasks[id] = Task {
            try? await Task.sleep(for: duration)
            if Task.isCancelled {
                settle(id, error: "Run cancelled")
            } else {
                settle(id)
            }
        }
    }
}
