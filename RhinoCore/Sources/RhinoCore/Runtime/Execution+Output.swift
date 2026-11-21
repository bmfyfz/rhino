import Foundation
import JavaScriptCore

// `output.json()` and its relatives, `notify()` and `memory`: what a run leaves behind.
extension Execution {
    // MARK: - Published values

    /// Publishes a value and returns its id, or "" when it is not shown.
    /// Only the script the user ran publishes: for a script called with
    /// `run()`, `output.json()` is what it hands back to its caller.
    func addOutput(runID: String, kind: String, json: String) -> String {
        // A script run by another keeps what it publishes to itself, like a
        // function's local work, unless it is a step of a pipeline.
        guard runID == rootID || publishingRuns.contains(runID), let kind = OutputValue.Kind(rawValue: kind) else { return "" }
        var json = json
        // An image named by a relative path lives in the run's output folder,
        // like every other relative path a script uses.
        if kind == .image,
           var source = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
           let path = source["path"] as? String {
            source["path"] = resolve(path: path).path(percentEncoded: false)
            if let data = try? JSONSerialization.data(withJSONObject: source) {
                json = String(decoding: data, as: UTF8.self)
            }
        }
        let value = OutputValue(id: UUID(), runID: runID, kind: kind, name: nil, json: masked(json), date: Date())
        outputs[value.id.uuidString] = value
        emit(.output(value))
        return value.id.uuidString
    }

    func nameOutput(id: String, name: String) {
        guard var value = outputs[id] else { return }
        let trimmed = masked(name).trimmingCharacters(in: .whitespacesAndNewlines)
        value.name = trimmed.isEmpty ? nil : trimmed
        outputs[id] = value
        emit(.output(value))
    }

    func nameFile(token: String, name: String) {
        guard var saved = savedFiles[token] else {
            // A download is named before it has arrived; the name waits for it.
            pendingFileNames[token] = masked(name)
            return
        }
        let trimmed = masked(name).trimmingCharacters(in: .whitespacesAndNewlines)
        saved.name = trimmed.isEmpty ? nil : trimmed
        savedFiles[token] = saved
        emit(.file(saved))
    }

    // MARK: - Earlier results

    /// `input.from()`: what another script last produced, from the archive
    /// of finished runs. Nothing is run.
    func lastRun(arguments: JSValue, callback: JSValue) {
        guard let id = register(callback) else { return }
        let name = arguments.forProperty("name").toString() ?? ""
        guard let script = provider.script(named: name)?.id else {
            return settle(id, error: "input.from(): there is no script called “\(name)”.")
        }
        let maxAge = arguments.forProperty("maxAge").toDouble()
        let archive = archive

        tasks[id] = Task {
            guard let record = await archive?.latestSuccessfulRun(of: script),
                  !(maxAge > 0 && Date().timeIntervalSince(record.summary.finishedAt) * 1000 > maxAge) else {
                // Never ran, never succeeded, or too long ago to count.
                return settle(id)
            }
            let stamp = ISO8601DateFormatter()
            var outputs: [[String: Any]] = []
            var files: [[String: Any]] = []
            for item in record.items {
                switch item {
                case .output(let value):
                    outputs.append(["name": value.name ?? "", "kind": value.kind.rawValue, "json": value.json])
                case .file(let saved):
                    // A file that has since been deleted is not offered.
                    let path = saved.url.path(percentEncoded: false)
                    guard FileManager.default.fileExists(atPath: path) else { continue }
                    let size = (try? saved.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    files.append(["name": saved.url.lastPathComponent, "label": saved.name ?? "", "path": path, "size": size])
                default:
                    continue
                }
            }
            settle(id, value: [
                "script": script,
                "startedAt": stamp.string(from: record.summary.startedAt),
                "finishedAt": stamp.string(from: record.summary.finishedAt),
                "resultJSON": record.summary.resultJSON ?? NSNull(),
                "outputs": outputs,
                "files": files,
            ] as [String: Any])
        }
    }

    // MARK: - Notifications

    func notify(runID: String, title: String, message: String) {
        notifications += 1
        guard notifications <= Engine.maxNotifications else {
            if notifications == Engine.maxNotifications + 1 {
                emit(.log(LogEntry(
                    id: UUID(), runID: runID, date: Date(), level: .warn,
                    message: "notify() was called more than \(Engine.maxNotifications) times in this run; the rest are not shown."
                )))
            }
            return
        }
        emit(.notification(RunNotification(id: UUID(), runID: runID, title: masked(title), message: masked(message), date: Date())))
    }

    // MARK: - Memory

    /// `memory.get`, `.set`, `.delete` and `.keys`, for the script the run is of.
    func remember(runID: String, arguments: JSValue, callback: JSValue) {
        guard let id = register(callback) else { return }
        guard let script = scriptOfRun[runID] else {
            return settle(id, error: "Memory is not available here.")
        }
        let key = arguments.forProperty("key").toString() ?? ""
        do {
            switch arguments.forProperty("action").toString() ?? "" {
            case "get":
                settle(id, value: memory.json(forKey: key, script: script))
            case "set":
                try memory.set(json: arguments.forProperty("json").toString() ?? "null", forKey: key, script: script)
                settle(id)
            case "delete":
                try memory.remove(key: key, script: script)
                settle(id)
            case "keys":
                settle(id, value: memory.keys(script: script))
            default:
                settle(id, error: "Unknown memory action.")
            }
        } catch {
            settle(id, error: "Could not save “\(key)” to memory: \(error.localizedDescription)")
        }
    }
}
