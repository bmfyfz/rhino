import RhinoCore
import Foundation
import SwiftData

/// One finished run in the history database. The columns are what lists and
/// the pruning need; everything the run did is in `record`.
@Model
final class StoredRun {
    @Attribute(.unique) var id: UUID
    /// The id of the script that was run.
    /// Stored under the name it had in the first history files.
    @Attribute(originalName: "module") var script: String
    var startedAt: Date
    var failed: Bool
    var scheduled: Bool
    /// An encoded `RunRecord`. Kept outside the table, since it can be large
    /// and is only read when the run is put back on screen.
    @Attribute(.externalStorage) var record: Data

    init(id: UUID, script: String, startedAt: Date, failed: Bool, scheduled: Bool, record: Data) {
        self.id = id
        self.script = script
        self.startedAt = startedAt
        self.failed = failed
        self.scheduled = scheduled
        self.record = record
    }
}

/// A run as the history menu lists it: when, how it started, how it ended.
struct RunListing: Identifiable, Hashable {
    enum Outcome {
        case running, finished, failed
    }

    let id: UUID
    let startedAt: Date
    let isScheduled: Bool
    var outcome: Outcome
}

/// The runs of every script, kept between launches.
final class RunHistory {
    /// How many runs of each script are kept; older ones are forgotten.
    static let runsKept = 50

    /// Kept for as long as the history is: a context does not keep its
    /// container alive by itself.
    private let container: ModelContainer?
    private let context: ModelContext?
    /// Why history is not being kept, when it is not.
    let problem: String?

    init(url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let container = try ModelContainer(for: StoredRun.self, configurations: ModelConfiguration(url: url))
            self.container = container
            context = container.mainContext
            problem = nil
        } catch {
            container = nil
            context = nil
            problem = error.localizedDescription
        }
    }

    /// Every script's runs, newest first, without reading what they did.
    func listings() -> [String: [RunListing]] {
        // `record` lives outside the table and is only loaded when it is read,
        // so listing runs stays cheap however much they logged.
        let descriptor = FetchDescriptor<StoredRun>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        let stored = (try? context?.fetch(descriptor)) ?? []
        return Dictionary(grouping: stored, by: \.script).mapValues { runs in
            runs.map { RunListing(id: $0.id, startedAt: $0.startedAt, isScheduled: $0.scheduled, outcome: $0.failed ? .failed : .finished) }
        }
    }

    /// Keeps a finished run, and forgets the script's oldest ones beyond `runsKept`.
    func save(_ record: RunRecord) throws {
        guard let context else { return }
        context.insert(StoredRun(
            id: record.id,
            script: record.script,
            startedAt: record.startedAt,
            failed: record.failed,
            scheduled: record.isScheduled,
            record: try record.encoded()
        ))

        try context.save()

        // Counted here, not with a fetch offset: an offset is not reliable
        // while the context has changes of its own.
        let script = record.script
        let runs = try context.fetch(FetchDescriptor<StoredRun>(
            predicate: #Predicate { $0.script == script },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        ))
        guard runs.count > Self.runsKept else { return }
        for run in runs.dropFirst(Self.runsKept) {
            context.delete(run)
        }
        try context.save()
    }

    /// Everything one run did. Nil when it is gone or can no longer be read.
    func record(_ id: UUID) -> RunRecord? {
        var descriptor = FetchDescriptor<StoredRun>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let stored = try? context?.fetch(descriptor).first else { return nil }
        return try? RunRecord(data: stored.record)
    }

    /// The newest run of a script that ended without an error, in full.
    func latestSuccessfulRun(of script: String) -> RunRecord? {
        var descriptor = FetchDescriptor<StoredRun>(
            predicate: #Predicate { $0.script == script && !$0.failed },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let stored = try? context?.fetch(descriptor).first else { return nil }
        return try? RunRecord(data: stored.record)
    }

    func remove(_ id: UUID) {
        try? context?.delete(model: StoredRun.self, where: #Predicate { $0.id == id })
        try? context?.save()
    }

    /// Carries a script's runs over to its new id after it was moved.
    func rename(script: String, to renamed: String) {
        guard let context else { return }
        let runs = (try? context.fetch(FetchDescriptor<StoredRun>(predicate: #Predicate { $0.script == script }))) ?? []
        for run in runs { run.script = renamed }
        try? context.save()
    }

    /// Forgets every run of a script.
    func removeAll(of script: String) {
        try? context?.delete(model: StoredRun.self, where: #Predicate { $0.script == script })
        try? context?.save()
    }
}

/// The history as the engine sees it, for `input.from()`.
nonisolated struct HistoryArchive: RunArchive {
    let history: RunHistory

    func latestSuccessfulRun(of script: String) async -> RunRecord? {
        // The database belongs to the main actor.
        await MainActor.run { history.latestSuccessfulRun(of: script) }
    }
}
