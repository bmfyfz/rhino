import Foundation
import UniformTypeIdentifiers
import JavaScriptCore

public struct ScriptSource: Sendable {
    /// Stable identifier: the file name without ".js".
    public let id: String
    public let source: String

    public init(id: String, source: String) {
        self.id = id
        self.source = source
    }
}

public protocol ScriptProvider: Sendable {
    /// Looks a script up by id or by display name.
    func script(named name: String) -> ScriptSource?
}

/// Runs scripts. Each top-level run gets a fresh JavaScript context, so runs
/// never share state; scripts chained with `run()` share their parent's context.
public final class Engine: Sendable {
    /// How often one run may call `ai.ask()` unless the caller says otherwise.
    /// Every call costs the user money; a loop should not spend it unnoticed.
    public static let defaultMaxAICalls = 25

    /// The most notifications one run may show. A `notify()` inside a loop
    /// over a thousand rows should not bury everything else on the screen.
    public static let maxNotifications = 10

    private let provider: any ScriptProvider
    private let runsDirectory: URL
    private let session: URLSession
    private let secrets: any SecretStore
    private let grants: (any SecretGrants)?
    private let memory: any MemoryStore
    private let ai: (any AIProvider)?
    private let archive: (any RunArchive)?
    private let shared: (any SharedFunctionProvider)?
    private let protectedDirectories: [URL]

    /// - Parameters:
    ///   - secrets: Where `secrets.get()` reads and saves. Without one,
    ///     secrets last only as long as the engine.
    ///   - grants: Which scripts may read which saved secrets; a script
    ///     that has no grant makes the user be asked. Without one, every
    ///     script may read every saved secret.
    ///   - memory: Where `memory` keeps what scripts remember. Without one,
    ///     it lasts only as long as the engine.
    ///   - ai: What answers `ai.ask()`. Without one, scripts that call it fail.
    ///   - archive: Where `input.from()` finds what scripts produced before.
    ///     Without one, it finds nothing.
    ///   - shared: The user's own functions, available in every script.
    ///   - protectedDirectories: Folders scripts may not write into with
    ///     `write()` or `output.file()`: where an app keeps its own data,
    ///     such as the scripts themselves. The runs directory is always allowed.
    public init(
        provider: any ScriptProvider,
        runsDirectory: URL,
        session: URLSession = .shared,
        secrets: any SecretStore = InMemorySecretStore(),
        grants: (any SecretGrants)? = nil,
        memory: any MemoryStore = InMemoryMemoryStore(),
        ai: (any AIProvider)? = nil,
        archive: (any RunArchive)? = nil,
        shared: (any SharedFunctionProvider)? = nil,
        protectedDirectories: [URL] = []
    ) {
        self.provider = provider
        self.runsDirectory = runsDirectory
        self.session = session
        self.secrets = secrets
        self.grants = grants
        self.memory = memory
        self.ai = ai
        self.archive = archive
        self.shared = shared
        self.protectedDirectories = protectedDirectories
    }

    /// Runs a script to completion. Cancelling the calling task stops the run.
    ///
    /// - Parameters:
    ///   - files: Files handed to the script through `input.file()`.
    ///   - data: What the script finds in `input.data`, as JSON text; for
    ///     whoever starts a script from outside, as `run(name, data)` does inside.
    ///   - interactive: When false nobody can answer `input.ask()`: it resolves to its
    ///     default, or fails the run if it has none. Use false for scheduled runs.
    ///   - events: Called on a background queue, in order, as the run progresses.
    @discardableResult
    public func run(
        _ name: String,
        files: [URL] = [],
        data: String? = nil,
        interactive: Bool = false,
        maxAICalls: Int = Engine.defaultMaxAICalls,
        events: @escaping @Sendable (RunEvent) -> Void = { _ in }
    ) async -> RunSummary {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted).dateSeparator(.omitted))
        let folder = "\(stamp)-\(name.replacing(/[^A-Za-z0-9_-]+/, with: "-"))-\(UUID().uuidString.prefix(6).lowercased())"
        let execution = Execution(
            provider: provider,
            session: session,
            outputDirectory: runsDirectory.appending(path: folder, directoryHint: .isDirectory),
            interactive: interactive,
            secrets: secrets,
            grants: grants,
            memory: memory,
            ai: ai,
            archive: archive,
            shared: shared,
            protectedDirectories: protectedDirectories,
            maxAICalls: maxAICalls,
            events: events
        )
        return await withTaskCancellationHandler {
            await execution.run(script: name, files: files, data: data)
        } onCancel: {
            Task { await execution.cancel() }
        }
    }
}
