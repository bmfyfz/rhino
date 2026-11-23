import AppKit
import RhinoControl
import RhinoCore

/// Answers the `rhino` command line tool: turns each request into work for
/// the app model, and the model's answers into what the tool prints.
///
/// Nothing here does anything the window cannot do, and two things the
/// window can do are left out on purpose: reading a secret's value, and
/// saying yes to a script that asks to run.
final class ControlService {
    private unowned let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    /// Does what was asked and sends the last message; a run sends its
    /// lines on the way.
    func answer(_ request: ControlRequest, on connection: ControlConnection) async {
        do {
            connection.send(.done(try await result(of: request, on: connection)))
        } catch {
            connection.send(.failed(error.localizedDescription))
        }
    }

    private func result(of request: ControlRequest, on connection: ControlConnection) async throws -> ControlResult {
        switch request {
        case .status:
            return .status(status())

        case .list:
            model.refreshFromDisk()
            return .scripts(model.scripts.map(info))

        case .show(let name):
            let script = try model.script(called: name)
            return .script(info(script), source: try model.store.source(of: script.id))

        case .create(let name, let folder, let source):
            let script = try model.createFromCommandLine(named: name, in: folder, source: source)
            return .script(info(script), source: "")

        case .write(let name, let source):
            let script = try model.writeFromCommandLine(try model.script(called: name), source: source)
            return .script(info(script), source: "")

        case .remove(let name):
            let script = try model.script(called: name)
            try model.removeFromCommandLine(script)
            return .ok("Moved \(script.id) to the Trash.")

        case .move(let name, let folder):
            let script = try model.moveFromCommandLine(try model.script(called: name), to: folder)
            return .script(info(script), source: "")

        case .check(let source, let name):
            if let name {
                let script = try model.script(called: name)
                let source = try model.store.source(of: script.id)
                return .check(check(source, unapproved: model.unapproved(script.id)))
            }
            return .check(check(source ?? "", unapproved: []))

        case .run(let name, let data, let files):
            return .run(try await run(try model.script(called: name), data: data, files: files, on: connection))

        case .stop(let name):
            let script = try model.script(called: name)
            try model.stopFromCommandLine(script)
            return .ok("Stopped \(script.id).")

        case .runs(let name, let limit):
            let only = try name.map { try model.script(called: $0).id }
            return .runs(runs(of: only, limit: limit))

        case .log(let run, let name):
            return .run(try log(run: run, script: name))

        case .open(let name):
            let script = try name.map { try model.script(called: $0) }
            model.openMainWindow?()
            NSApplication.shared.activate()
            if let script { model.select(script.id) }
            return .ok("")

        case .api:
            return .text(API.typeDefinitions)

        case .secrets:
            model.refreshSecretNames()
            return .secrets(model.secretNames.map { SecretInfo(name: $0, scripts: model.secretAccess[$0] ?? []) })

        case .functions:
            let files = model.functions.sharedFiles()
            return .functions(files.map { file in
                FunctionsInfo(
                    name: file.id,
                    defines: SharedLibrary.names(definedIn: file.source),
                    problem: SharedLibrary.problem(in: file, among: files.filter { $0.id != file.id })
                )
            })

        case .showFunctions(let name):
            guard let file = model.functions.sharedFiles().first(where: { $0.id == name }) else {
                throw AppModel.Problem("There is no file of shared functions called “\(name)”. `rhino functions` lists them.")
            }
            return .text(file.source)

        case .writeFunctions(let name, let source):
            let others = model.functions.sharedFiles().filter { $0.id != name }
            if let problem = SharedLibrary.problem(in: SharedFile(id: name, source: source), among: others) {
                throw AppModel.Problem("Not saved: \(problem)")
            }
            try model.functions.save(source, to: name)
            return .ok("Saved the shared functions in \(name).")

        case .removeFunctions(let name):
            guard model.functions.sharedFiles().contains(where: { $0.id == name }) else {
                throw AppModel.Problem("There is no file of shared functions called “\(name)”.")
            }
            try model.functions.delete(name)
            return .ok("Moved the shared functions in \(name) to the Trash.")

        case .schedules(let paused):
            if let paused { model.schedulesPaused = paused }
            return .status(status())
        }
    }

    // MARK: - Running

    /// Runs a script while the tool watches. If the tool goes away (the
    /// person pressed Control-C), the run is stopped.
    private func run(_ script: Script, data: String?, files: [String], on connection: ControlConnection) async throws -> RunReport {
        var scripts: [String: String] = [:]
        // A file or a published value is announced once. The script names
        // it a moment after making it, so the line waits for the next event
        // and goes out with the name.
        var held: (id: UUID, item: RunRecord.Item)?
        var announced: Set<UUID> = []
        func sendHeld() {
            guard let waiting = held else { return }
            held = nil
            connection.send(.line(Self.line(waiting.item, scripts: scripts)))
        }
        func announce(_ id: UUID, _ item: RunRecord.Item) {
            if held?.id == id {
                held = (id, item)
            } else if announced.insert(id).inserted {
                sendHeld()
                held = (id, item)
            }
        }
        let model = model
        let work = Task {
            let record = try await model.runFromCommandLine(
                script, data: data, files: files.map { URL(fileURLWithPath: $0) },
                waiting: { connection.send(.waiting($0)) },
                events: { event in
                    switch event {
                    case .runStarted(let run):
                        scripts[run.id] = run.script
                    case .file(let file):
                        announce(file.id, .file(file))
                    case .output(let output):
                        announce(output.id, .output(output))
                    case .log(let entry):
                        sendHeld()
                        connection.send(.line(Self.line(.log(entry), scripts: scripts)))
                    case .spanFinished(let span):
                        sendHeld()
                        connection.send(.line(Self.line(.call(span), scripts: scripts)))
                    case .notification(let notification):
                        sendHeld()
                        connection.send(.line(Self.line(.notification(notification), scripts: scripts)))
                    case .runFinished, .spanStarted, .prompt, .promptResolved:
                        break
                    }
                }
            )
            sendHeld()
            return record
        }
        connection.whenClosed { work.cancel() }
        return Self.report(try await work.value)
    }

    // MARK: - What the app knows, as the tool prints it

    private func info(_ script: Script) -> ScriptInfo {
        let latest = model.history[script.id]?.first
        return ScriptInfo(
            id: script.id,
            name: script.name,
            description: script.summary,
            folder: script.folder,
            schedule: script.schedule,
            watch: script.watch,
            key: script.shortcut?.symbols,
            path: script.url.path(percentEncoded: false),
            running: model.runningSession(of: script.id) != nil,
            nextRun: model.schedulesPaused ? nil : model.schedules[script.id]?.next,
            lastRun: latest.map { detailed($0, of: script.id) },
            needsApproval: !model.unapproved(script.id).isEmpty
        )
    }

    private func brief(_ listing: RunListing, of script: String) -> RunBrief {
        let status: RunBrief.Status = switch listing.outcome {
        case .running: .running
        case .finished: .finished
        case .failed: .failed
        }
        return RunBrief(id: listing.id.uuidString, script: script, startedAt: listing.startedAt, status: status)
    }

    /// A run with what its record knows: how long it took, what started
    /// it, and whether it failed or was stopped. The script is named by the
    /// id it has today; the record keeps the one it had when it ran.
    private func detailed(_ listing: RunListing, of script: String) -> RunBrief {
        guard listing.outcome != .running, let record = model.record(of: listing.id) else {
            return brief(listing, of: script)
        }
        var run = Self.brief(record)
        run.script = script
        return run
    }

    private func runs(of script: String?, limit: Int) -> [RunBrief] {
        model.history
            .filter { script == nil || $0.key == script }
            .flatMap { id, runs in runs.map { (script: id, listing: $0) } }
            .sorted { $0.listing.startedAt > $1.listing.startedAt }
            .prefix(max(1, min(limit, 200)))
            .map { detailed($0.listing, of: $0.script) }
    }

    private func log(run: String?, script name: String?) throws -> RunReport {
        if let run {
            guard let id = UUID(uuidString: run), let record = model.record(of: id) else {
                throw AppModel.Problem("There is no finished run with the id \(run). `rhino runs` lists them.")
            }
            let script = model.history.first { $0.value.contains { $0.id == id } }?.key
            return Self.report(record, script: script)
        }
        let script = try model.script(called: name ?? "")
        guard let latest = model.history[script.id]?.first(where: { $0.outcome != .running }), let record = model.record(of: latest.id) else {
            throw AppModel.Problem("“\(script.name)” has no finished run yet.")
        }
        return Self.report(record, script: script.id)
    }

    private func check(_ source: String, unapproved: [ScriptFootprint.Item]) -> CheckReport {
        if let problem = ScriptCompiler.syntaxProblem(in: source) {
            return CheckReport(problem: problem)
        }
        return CheckReport(touches: ScriptFootprint(of: source).items.sorted().map(\.summary), unapproved: unapproved.map(\.summary))
    }

    private func status() -> StatusReport {
        model.refreshFromDisk()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ControlProtocol.toolVersion
        let running = model.scripts.compactMap { script in
            model.runningSession(of: script.id).map {
                RunBrief(id: $0.id.uuidString, script: script.id, startedAt: $0.startedAt, status: .running, trigger: $0.trigger.rawValue)
            }
        }
        return StatusReport(
            version: version,
            scripts: model.scripts.count,
            running: running,
            scheduled: model.schedules.sorted { $0.key < $1.key }.map {
                StatusReport.Scheduled(script: $0.key, schedule: $0.value.text, next: model.schedulesPaused ? nil : $0.value.next, problem: $0.value.problem)
            },
            watched: model.watches.sorted { $0.key < $1.key }.map {
                StatusReport.Watched(script: $0.key, folder: $0.value.text, problem: $0.value.problem)
            },
            schedulesPaused: model.schedulesPaused,
            awaitingApproval: model.scriptsAwaitingApproval
        )
    }

    // MARK: - Runs

    private static func brief(_ record: RunRecord) -> RunBrief {
        let error = record.summary.error
        return RunBrief(
            id: record.id.uuidString,
            script: record.script,
            startedAt: record.startedAt,
            duration: record.summary.duration,
            status: error == nil ? .finished : error?.isCancellation == true ? .stopped : .failed,
            trigger: record.trigger ?? (record.isScheduled ? "schedule" : "manual"),
            error: error?.message
        )
    }

    /// A finished run as the tool prints it: every item once, as it was at
    /// the end, in the order it first appeared.
    private static func report(_ record: RunRecord, script: String? = nil) -> RunReport {
        let scripts = Dictionary(record.runs.map { ($0.id, $0.script) }, uniquingKeysWith: { first, _ in first })
        var latest: [UUID: RunRecord.Item] = [:]
        var order: [UUID] = []
        for item in record.items {
            let id: UUID = switch item {
            case .log(let entry): entry.id
            case .call(let span): span.id
            case .file(let file): file.id
            case .question(let question): question.id
            case .output(let output): output.id
            case .notification(let notification): notification.id
            }
            if latest[id] == nil { order.append(id) }
            latest[id] = item
        }
        let items = order.compactMap { latest[$0] }

        let outputs = items.compactMap { item -> RunReport.Output? in
            guard case .output(let output) = item else { return nil }
            return RunReport.Output(name: name(of: output), kind: output.kind.rawValue, value: JSONValue(json: output.json) ?? .string(output.json))
        }
        let files = items.compactMap { item -> RunReport.File? in
            guard case .file(let file) = item else { return nil }
            let path = file.url.path(percentEncoded: false)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            return RunReport.File(name: file.name ?? file.url.lastPathComponent, path: path, bytes: bytes)
        }
        let failure = record.summary.error.map {
            RunReport.Failure(name: $0.name, message: $0.message, script: $0.script, line: $0.line)
        }
        var run = brief(record)
        if let script { run.script = script }
        return RunReport(
            run: run,
            result: record.summary.resultJSON.flatMap(JSONValue.init(json:)),
            error: failure,
            outputs: outputs,
            files: files,
            log: items.map { line($0, scripts: scripts) }
        )
    }

    private static func name(of output: OutputValue) -> String {
        output.name ?? {
            switch output.kind {
            case .json: "Result"
            case .image: "Image"
            case .chart: "Chart"
            case .table: "Table"
            case .text: "Note"
            }
        }()
    }

    /// One thing a run did, as one line.
    private static func line(_ item: RunRecord.Item, scripts: [String: String]) -> RunLine {
        func script(_ run: String) -> String { scripts[run] ?? "" }
        switch item {
        case .log(let entry):
            return RunLine(time: entry.date, script: script(entry.runID), kind: .log, text: entry.message, level: entry.level.rawValue)
        case .call(let span):
            let milliseconds = span.duration.map { Int(($0 * 1000).rounded()) }
            let outcome = span.status.map(String.init) ?? "failed"
            var text = "\(span.method) \(outcome) \(span.url)"
            if let milliseconds { text += "  \(milliseconds) ms" }
            if let error = span.error { text += "  \(error)" }
            return RunLine(time: span.startedAt, script: script(span.runID), kind: .call, text: text, method: span.method, url: span.url, status: span.status, milliseconds: milliseconds)
        case .file(let file):
            let path = file.url.path(percentEncoded: false)
            return RunLine(time: file.date, script: script(file.runID), kind: .file, text: "\(file.name ?? file.url.lastPathComponent)  \(path)", path: path)
        case .output(let output):
            return RunLine(time: output.date, script: script(output.runID), kind: .output, text: "\(output.kind.rawValue)  \(name(of: output))")
        case .notification(let notification):
            let text = notification.message.isEmpty ? notification.title : "\(notification.title): \(notification.message)"
            return RunLine(time: notification.date, script: script(notification.runID), kind: .notification, text: text)
        case .question(let question):
            return RunLine(time: question.askedAt, script: script(question.runID), kind: .question, text: "\(question.message) → \(question.answer ?? "no answer")")
        }
    }
}
