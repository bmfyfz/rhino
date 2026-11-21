import Foundation
import JavaScriptCore

/// One top-level run. The actor's executor is a serial queue, and every touch
/// of the JavaScript context happens on it: JavaScriptCore calls the host
/// functions synchronously while a script runs, so they are on the actor too.
actor Execution {
    nonisolated let queue = DispatchSerialQueue(label: "rhino.execution")
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    static let maxRecordedBody = 512 * 1024

    let provider: any ScriptProvider
    let session: URLSession
    let outputDirectory: URL
    let interactive: Bool
    let secrets: any SecretStore
    let grants: (any SecretGrants)?
    let memory: any MemoryStore
    let ai: (any AIProvider)?
    let archive: (any RunArchive)?
    let shared: (any SharedFunctionProvider)?
    let protectedDirectories: [URL]
    /// The names the user's shared functions define, for scripts to use.
    var sharedNames: [String] = []
    let maxAICalls: Int
    let events: @Sendable (RunEvent) -> Void

    var context: JSContext?
    var waiter: CheckedContinuation<Void, Never>?
    var finished = false
    var cancelled = false

    var rootID: String?
    var rootError: RunError?
    var rootResult: String?

    /// JavaScript callbacks waiting for native work, by operation id.
    var pending: [UUID: JSValue] = [:]
    var tasks: [UUID: Task<Void, Never>] = [:]
    /// Files saved with `output.file()`, by the token the script's side refers to them with.
    var savedFiles: [String: SavedFile] = [:]
    /// Values published with `output.json()`, kept so a later `.name()` can update them.
    var outputs: [String: OutputValue] = [:]
    /// The fields of forms waiting for an answer, needed to encode the answer.
    var forms: [UUID: [FormField]] = [:]
    /// Which script each run is of; memory is kept per script.
    var scriptOfRun: [String: String] = [:]
    /// A secret a script is waiting for, and which script that is.
    struct SecretRequest {
        let name: String
        let script: String
    }
    /// Questions whose answer is a secret to save.
    var askedSecrets: [UUID: SecretRequest] = [:]
    /// Questions whether a script may use a secret that is already saved.
    var secretPermissions: [UUID: SecretRequest] = [:]
    /// The secrets this run has handled, kept out of what it records.
    var masker = SecretMasker()
    /// Chained runs whose published values are shown: the steps of a pipeline.
    var publishingRuns: Set<String> = []
    /// Questions asked with type "secret": their answers are secrets too.
    var secretQuestions: Set<UUID> = []
    /// How often `notify()` was called, counting chained scripts too.
    var notifications = 0
    /// How often `ai.ask()` was called, counting chained scripts too.
    var aiCalls = 0
    /// Names given to files that are still being downloaded, by token.
    var pendingFileNames: [String: String] = [:]

    init(
        provider: any ScriptProvider,
        session: URLSession,
        outputDirectory: URL,
        interactive: Bool,
        secrets: any SecretStore,
        grants: (any SecretGrants)?,
        memory: any MemoryStore,
        ai: (any AIProvider)?,
        archive: (any RunArchive)?,
        shared: (any SharedFunctionProvider)?,
        protectedDirectories: [URL],
        maxAICalls: Int,
        events: @escaping @Sendable (RunEvent) -> Void
    ) {
        self.maxAICalls = maxAICalls
        self.provider = provider
        self.session = session
        self.outputDirectory = outputDirectory
        self.interactive = interactive
        self.secrets = secrets
        self.grants = grants
        self.memory = memory
        self.ai = ai
        self.archive = archive
        self.shared = shared
        self.protectedDirectories = protectedDirectories
        self.events = events
    }

    // MARK: - Lifecycle

    func run(script name: String, files: [URL], data: String?) async -> RunSummary {
        let startedAt = Date()
        boot(script: name, files: files, data: data)
        if !finished {
            await withCheckedContinuation { waiter = $0 }
        }
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        pending.removeAll()
        context = nil
        return RunSummary(
            error: rootError,
            resultJSON: rootResult,
            outputDirectory: outputDirectory,
            startedAt: startedAt,
            finishedAt: Date()
        )
    }

    /// Ends the run here and now. The script is not asked to unwind: one
    /// that catches errors and retries would never let go, and one waiting
    /// on something that never happens has nothing to be told. Only code
    /// that never yields (`while (true) {}`) cannot be stopped this way.
    func cancel() {
        guard !finished, !cancelled else { return }
        cancelled = true
        for task in tasks.values { task.cancel() }
        pending.removeAll()
        rootError = RunError(name: RunError.cancelledName, message: "Run cancelled")
        finish()
    }

    func boot(script name: String, files: [URL], data: String?) {
        guard let context = JSContext(virtualMachine: JSVirtualMachine()),
              let host = JSValue(newObjectIn: context) else {
            return abort("Could not create a JavaScript context")
        }
        self.context = context
        // Before the host functions, which hand the shared names to every script they load.
        guard let factories = loadShared(in: context) else { return }
        host.setObject(factories, forKeyedSubscript: "sharedFactories" as NSString)
        install(on: host)

        let prelude = context.evaluateScript(API.prelude, withSourceURL: URL(string: "rhino-internal:///prelude.js"))
        guard let start = prelude?.call(withArguments: [host]), context.exception == nil, !start.isUndefined else {
            return abort("Runtime failed to start: \(context.exception?.toString() ?? "unknown error")")
        }

        let done: @convention(block) () -> Void = { [weak self] in
            self?.assumeIsolated { $0.finish() }
        }
        let fileInfos = files.map { url -> [String: Any] in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return ["name": url.lastPathComponent, "path": url.path(percentEncoded: false), "size": size]
        }
        start.call(withArguments: [name, fileInfos, unsafeBitCast(done, to: AnyObject.self), data ?? NSNull()])
        if let exception = context.exception, !finished {
            abort("Runtime error: \(exception.toString() ?? "unknown error")")
        }
    }

    /// Compiles the user's shared functions: one function per file that,
    /// given a run's API, returns what the file defines. Returns nil, after
    /// ending the run, when a file cannot be used; running scripts against
    /// half of the functions they expect would only fail more obscurely.
    private func loadShared(in context: JSContext) -> [JSValue]? {
        var factories: [JSValue] = []
        for file in shared?.sharedFiles() ?? [] {
            let names = SharedLibrary.names(definedIn: file.source).filter { !ScriptCompiler.globals.contains($0) && !sharedNames.contains($0) }
            let program = SharedLibrary.wrap(file.source, names: names, visible: ScriptCompiler.globals + sharedNames)
            let factory = context.evaluateScript(program, withSourceURL: Self.sourceURL(for: SharedLibrary.location(of: file)))
            if let exception = context.exception {
                context.exception = nil
                let line = exception.forProperty("line").flatMap { $0.isNumber ? " (line \($0.toInt32()))" : nil } ?? ""
                abort("Your shared functions in “\(file.id)” have a mistake: \(exception.toString() ?? "unknown error")\(line). Fix it in Settings, under Functions.")
                return nil
            }
            guard let factory, !factory.isUndefined else { continue }
            factories.append(factory)
            sharedNames += names
        }
        return factories
    }

    func abort(_ message: String) {
        rootError = RunError(name: "InternalError", message: message)
        finish()
    }

    func finish() {
        guard !finished else { return }
        finished = true
        waiter?.resume()
        waiter = nil
    }

    // MARK: - Host functions

    func install(on host: JSValue) {
        func set<Block>(_ name: String, _ block: Block) {
            host.setObject(unsafeBitCast(block, to: AnyObject.self), forKeyedSubscript: name as NSString)
        }
        typealias Operation = @convention(block) (String, JSValue, JSValue) -> Void

        let beginRun: @convention(block) (String, JSValue, Bool) -> String = { [weak self] name, parent, publishes in
            let parentID = parent.isString ? parent.toString() : nil
            return self?.assumeIsolated { $0.beginRun(name: name, parentID: parentID, publishes: publishes) } ?? ""
        }
        set("beginRun", beginRun)

        // Runs on the actor's queue like every other host function, but returns
        // a JSValue, which cannot cross `assumeIsolated`. It only needs the
        // provider, which is safe to use from anywhere.
        let provider = provider
        let sharedNames = sharedNames
        let load: @convention(block) (String) -> JSValue? = { name in
            guard let context = JSContext.current() else { return nil }
            guard let script = provider.script(named: name) else {
                context.exception = JSValue(newErrorFromMessage: "Script not found: \"\(name)\"", in: context)
                return nil
            }
            do {
                let program = try ScriptCompiler.wrap(script.source, shared: sharedNames)
                return context.evaluateScript(program, withSourceURL: Self.sourceURL(for: script.id))
            } catch {
                context.exception = JSValue(newErrorFromMessage: "\(error)", in: context)
                return nil
            }
        }
        set("load", load)

        let endRun: @convention(block) (String, JSValue, JSValue) -> Void = { [weak self] runID, error, result in
            let failure = error.isObject ? Self.runError(from: error) : nil
            let json = result.isString ? result.toString() : nil
            self?.assumeIsolated { $0.endRun(runID, error: failure, resultJSON: json) }
        }
        set("endRun", endRun)

        let addOutput: @convention(block) (String, String, String) -> String = { [weak self] runID, kind, json in
            self?.assumeIsolated { $0.addOutput(runID: runID, kind: kind, json: json) } ?? ""
        }
        set("output", addOutput)

        let nameOutput: @convention(block) (String, String) -> Void = { [weak self] id, name in
            self?.assumeIsolated { $0.nameOutput(id: id, name: name) }
        }
        set("nameOutput", nameOutput)

        let nameFile: @convention(block) (String, String) -> Void = { [weak self] token, name in
            self?.assumeIsolated { $0.nameFile(token: token, name: name) }
        }
        set("nameFile", nameFile)

        let log: @convention(block) (String, String, String) -> Void = { [weak self] runID, level, message in
            self?.assumeIsolated { execution in
                execution.emit(.log(LogEntry(
                    id: UUID(), runID: runID, date: Date(),
                    level: LogLevel(rawValue: level) ?? .info,
                    message: execution.masked(message)
                )))
            }
        }
        set("log", log)

        let notify: @convention(block) (String, String, String) -> Void = { [weak self] runID, title, message in
            self?.assumeIsolated { $0.notify(runID: runID, title: title, message: message) }
        }
        set("notify", notify)

        // JavaScriptCore calls these on the actor's queue, so hopping onto the
        // actor is synchronous. JSValue is not Sendable, and the compiler cannot
        // see that both sides are the same queue, hence `nonisolated(unsafe)`.
        func operation(_ name: String, _ body: @escaping @Sendable (isolated Execution, String, JSValue, JSValue) -> Void) {
            let block: Operation = { [weak self] runID, arguments, callback in
                nonisolated(unsafe) let arguments = arguments
                nonisolated(unsafe) let callback = callback
                self?.assumeIsolated { body($0, runID, arguments, callback) }
            }
            set(name, block)
        }

        operation("http") { $0.http(runID: $1, arguments: $2, callback: $3) }
        operation("download") { $0.download(runID: $1, arguments: $2, callback: $3) }
        operation("readFile") { $0.readFile(arguments: $2, callback: $3) }
        operation("writeFile") { $0.writeFile(runID: $1, arguments: $2, callback: $3) }
        operation("sleep") { $0.sleep(milliseconds: $2.forProperty("ms").toDouble(), callback: $3) }
        operation("ask") { $0.ask(runID: $1, arguments: $2, callback: $3) }
        operation("form") { $0.form(runID: $1, arguments: $2, callback: $3) }
        operation("secret") { $0.secret(runID: $1, arguments: $2, callback: $3) }
        operation("memory") { $0.remember(runID: $1, arguments: $2, callback: $3) }
        operation("ai") { $0.askAI(runID: $1, arguments: $2, callback: $3) }
        operation("aiImage") { $0.makePicture(runID: $1, arguments: $2, callback: $3) }
        operation("lastRun") { $0.lastRun(arguments: $2, callback: $3) }
        operation("shell") { $0.shell(runID: $1, arguments: $2, callback: $3) }

        operation("fileExists") { execution, _, arguments, callback in
            guard let id = execution.register(callback) else { return }
            let url = execution.resolve(path: arguments.forProperty("path").toString())
            execution.settle(id, value: FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        }

        operation("listDirectory") { execution, _, arguments, callback in
            guard let id = execution.register(callback) else { return }
            let url = execution.resolve(path: arguments.forProperty("path").toString())
            do {
                let names = try FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))
                execution.settle(id, value: names.sorted())
            } catch {
                execution.settle(id, error: "Cannot list \(url.path(percentEncoded: false)): \(error.localizedDescription)")
            }
        }
    }

    // MARK: Runs

    func beginRun(name: String, parentID: String?, publishes: Bool) -> String {
        let id = UUID().uuidString
        if parentID == nil { rootID = id }
        if publishes { publishingRuns.insert(id) }
        let script = provider.script(named: name)?.id ?? name
        scriptOfRun[id] = script
        emit(.runStarted(RunInfo(id: id, script: script, parentID: parentID, startedAt: Date())))
        return id
    }

    func endRun(_ runID: String, error: RunError?, resultJSON: String?) {
        // A cancelled run has its outcome already; what the script does on
        // its way out does not change it.
        guard !cancelled else { return }
        // An error often quotes what failed, such as an address with a key in it.
        var error = error
        if let failure = error {
            error = RunError(
                name: masker.mask(failure.name), message: masker.mask(failure.message),
                script: failure.script, line: failure.line, stack: masker.mask(failure.stack)
            )
        }
        let resultJSON = resultJSON.map(masker.mask)
        if runID == rootID {
            rootError = error
            rootResult = resultJSON
        }
        emit(.runFinished(runID: runID, at: Date(), error: error, resultJSON: resultJSON))
    }


    // MARK: - Pending operations

    /// Remembers a JavaScript callback until its native work is done.
    /// Returns nil when the run is over: the callback is dropped, not
    /// failed, so a script that retries on errors cannot spin.
    func register(_ callback: JSValue) -> UUID? {
        if cancelled || finished { return nil }
        let id = UUID()
        pending[id] = callback
        return id
    }

    func settle(_ id: UUID, value: Any? = nil) {
        tasks[id] = nil
        guard let callback = pending.removeValue(forKey: id), !finished else { return }
        callback.call(withArguments: [NSNull(), value ?? NSNull()])
    }

    func settle(_ id: UUID, error: String) {
        tasks[id] = nil
        guard let callback = pending.removeValue(forKey: id), !finished else { return }
        callback.call(withArguments: [error])
    }

    // MARK: - Helpers

    nonisolated func emit(_ event: RunEvent) {
        events(event)
    }

    static func truncated(_ text: String) -> String {
        guard text.utf8.count > maxRecordedBody else { return text }
        return String(text.prefix(maxRecordedBody)) + "\n… truncated"
    }

    static func sourceURL(for scriptID: String) -> URL? {
        let encoded = scriptID.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-_."))) ?? "script"
        return URL(string: "rhino:///\(encoded).js")
    }

    /// Builds a `RunError` from the object `describe()` produces in the prelude,
    /// locating the script and line from the first stack frame inside a script.
    static func runError(from value: JSValue) -> RunError {
        let name = value.forProperty("name").toString() ?? "Error"
        let message = value.forProperty("message").toString() ?? "Unknown error"
        let stack = value.forProperty("stack").toString() ?? ""
        var error = RunError(name: name, message: message, stack: stack)

        if let match = stack.firstMatch(of: /rhino:\/\/\/([^\s:]+)\.js:(\d+)/) {
            error.script = String(match.1).removingPercentEncoding
            error.line = Int(match.2)
        } else if let source = value.forProperty("sourceURL").toString(),
                  let match = source.firstMatch(of: /^rhino:\/\/\/(.+)\.js$/) {
            // Syntax errors have no stack, only the location of the bad token.
            error.script = String(match.1).removingPercentEncoding
            let line = Int(value.forProperty("line").toInt32())
            error.line = line > 0 ? line : nil
        }
        return error
    }
}
