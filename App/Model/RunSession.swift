import Foundation
import Observation
import RhinoCore

/// One run of a script as the window shows it, including any chained scripts.
@Observable
final class RunSession: Identifiable {
    /// One line of the output, in the order things happened.
    enum Entry: Identifiable {
        case log(LogEntry)
        /// An HTTP call; its current state is in `spans`.
        case span(UUID)
        case file(id: UUID, runID: String, url: URL, date: Date)
        /// A question; its current state is in `questions`.
        case question(UUID)
        /// A published value; its current state is in `outputs`.
        case output(UUID)
        /// Something the script said with `notify()`.
        case notification(RunNotification)

        var id: UUID {
            switch self {
            case .log(let entry): entry.id
            case .notification(let notification): notification.id
            case .span(let id), .question(let id), .output(let id): id
            case .file(let id, _, _, _): id
            }
        }
    }

    struct Question {
        let request: PromptRequest
        var askedAt = Date()
        /// What the user answered, as shown in the output once it is settled.
        var answer: String?
        /// For a submitted form: the value of each field.
        var formValues: [String: FormValue]?
        var isPending = true
    }

    enum Trigger: String {
        /// The user pressed Run.
        case manual
        /// The script's schedule came due.
        case schedule
        /// A file arrived in the folder the script watches.
        case folder
        /// The Shortcuts app asked for it.
        case shortcut
    }

    let id: UUID
    let script: Script
    let trigger: Trigger
    let startedAt: Date

    private(set) var runs: [RunInfo] = []
    private(set) var entries: [Entry] = []
    private(set) var spans: [UUID: HTTPSpan] = [:]
    private(set) var questions: [UUID: Question] = [:]
    private(set) var outputs: [UUID: OutputValue] = [:]
    /// Every file the run wrote, for the sidebar.
    private(set) var files: [URL] = []
    /// The names scripts gave their files with `.name()`.
    private var fileNames: [URL: String] = [:]
    private var knownFiles: Set<UUID> = []
    private(set) var summary: RunSummary?
    /// The artifact that is current: the newest one, or the one the user picked.
    private(set) var selectedArtifact: ArtifactID?
    /// The preview keeps the newest item in view until the user picks one.
    private(set) var followsNewest = true
    /// Counts the user's picks, so picking the same item twice is still noticed.
    private(set) var picks = 0

    @ObservationIgnored var onStop: (() -> Void)?

    init(script: Script, trigger: Trigger = .manual) {
        id = UUID()
        self.script = script
        self.trigger = trigger
        startedAt = Date()
    }

    /// A run from the history, as it was when it ended.
    init(script: Script, record: RunRecord) {
        id = record.id
        self.script = script
        trigger = record.trigger.flatMap(Trigger.init) ?? (record.isScheduled ? .schedule : .manual)
        startedAt = record.startedAt
        runs = record.runs
        for item in record.items {
            switch item {
            case .log(let entry): apply(.log(entry))
            case .call(let span): apply(.spanStarted(span))
            case .file(let file): apply(.file(file))
            case .output(let value): apply(.output(value))
            case .notification(let notification): apply(.notification(notification))
            case .question(let question):
                questions[question.id] = Question(
                    request: PromptRequest(question),
                    askedAt: question.askedAt,
                    answer: question.answer,
                    formValues: question.formValues,
                    isPending: false
                )
                entries.append(.question(question.id))
            }
        }
        complete(record.summary)
    }

    /// A form's values as they may be kept: what was typed into a secret
    /// field is replaced by dots, since the history is an ordinary file.
    private static func withoutSecrets(_ values: [String: FormValue]?, of request: PromptRequest) -> [String: FormValue]? {
        guard var values else { return nil }
        for field in request.fields where field.kind == .secret {
            if case .text(let typed) = values[field.id], !typed.isEmpty {
                values[field.id] = .text(String(repeating: "•", count: 8))
            }
        }
        return values
    }

    /// The finished run as the history keeps it. Nil while it is running.
    var record: RunRecord? {
        guard let summary else { return nil }
        let items = entries.compactMap { entry -> RunRecord.Item? in
            switch entry {
            case .log(let log):
                .log(log)
            case .span(let id):
                spans[id].map { .call($0) }
            case .file(let id, let runID, let url, let date):
                .file(SavedFile(id: id, runID: runID, url: url, name: fileNames[url], date: date))
            case .question(let id):
                questions[id].map {
                    .question(RunRecord.Question(request: $0.request, askedAt: $0.askedAt, answer: $0.answer, formValues: Self.withoutSecrets($0.formValues, of: $0.request)))
                }
            case .output(let id):
                outputs[id].map { .output($0) }
            case .notification(let notification):
                .notification(notification)
            }
        }
        return RunRecord(
            id: id, script: script.id, isScheduled: trigger != .manual, trigger: trigger == .manual ? nil : trigger.rawValue,
            summary: summary, runs: runs, items: items
        )
    }

    var isRunning: Bool { summary == nil }

    /// More than one script took part, so rows should say which one they belong to.
    var isChained: Bool { runs.count > 1 }

    var pendingQuestions: [PromptRequest] {
        entries.compactMap { entry in
            guard case .question(let id) = entry, let question = questions[id], question.isPending else { return nil }
            return question.request
        }
    }

    /// Published values, oldest first.
    var outputIDs: [UUID] {
        entries.compactMap { entry in
            if case .output(let id) = entry { id } else { nil }
        }
    }

    /// What a published item is called: the name the script gave it, or what
    /// kind of thing it is ("Result", "Chart", …), numbered when several of
    /// a kind are unnamed.
    func outputName(_ id: UUID) -> String {
        guard let output = outputs[id] else { return "Result" }
        if let name = output.name { return name }
        let fallback = switch output.kind {
        case .json: "Result"
        case .image: "Image"
        case .chart: "Chart"
        case .table: "Table"
        case .text: "Note"
        }
        let unnamed = outputIDs.filter { outputs[$0]?.name == nil && outputs[$0]?.kind == output.kind }
        guard unnamed.count > 1, let index = unnamed.firstIndex(of: id) else { return fallback }
        return "\(fallback) \(index + 1)"
    }

    /// One line about a published item, for lists.
    func outputDetail(_ id: UUID) -> String {
        guard let output = outputs[id] else { return "" }
        switch output.kind {
        case .json:
            return "JSON, \(output.json.utf8.count.formatted(.byteCount(style: .file)))"
        case .image:
            return "Image"
        case .chart:
            let points = ChartData(json: output.json)?.points.count ?? 0
            return "Chart, \(points) \(points == 1 ? "point" : "points")"
        case .table:
            let rows = TableData(json: output.json)?.totalRows ?? 0
            return "Table, \(rows) \(rows == 1 ? "row" : "rows")"
        case .text:
            return "Note"
        }
    }

    /// What a saved file is called: the name the script gave it, or its file name.
    func fileTitle(_ url: URL) -> String {
        fileNames[url] ?? url.lastPathComponent
    }

    /// Whether the script gave this file a name of its own.
    func isNamed(_ url: URL) -> Bool {
        fileNames[url] != nil
    }

    /// Everything the run produced that can be looked at, in the order it
    /// appeared: filled-in forms, published items, saved files.
    var artifacts: [ArtifactID] {
        var seen: Set<ArtifactID> = []
        return entries.compactMap { entry -> ArtifactID? in
            let artifact: ArtifactID? = switch entry {
            case .output(let id): .output(id)
            case .file(_, _, let url, _): .file(url)
            case .question(let id): questions[id]?.formValues != nil ? .form(id) : nil
            case .log, .span, .notification: nil
            }
            // A file written twice is still one file.
            guard let artifact, seen.insert(artifact).inserted else { return nil }
            return artifact
        }
    }

    /// The item marked as current in the console and the files list.
    var shownArtifact: ArtifactID? {
        selectedArtifact ?? artifacts.last
    }

    /// The user chose what to look at; the preview jumps to it and stops
    /// following the run.
    func pick(_ artifact: ArtifactID) {
        selectedArtifact = artifact
        followsNewest = false
        picks += 1
    }

    /// Forms that were filled in and submitted, oldest first.
    var submittedForms: [UUID] {
        entries.compactMap { entry in
            guard case .question(let id) = entry, questions[id]?.formValues != nil else { return nil }
            return id
        }
    }

    func scriptName(for runID: String) -> String {
        runs.first { $0.id == runID }?.script ?? script.id
    }

    func stop() {
        onStop?()
    }

    func answer(_ request: PromptRequest, with answer: PromptRequest.Answer) {
        questions[request.id]?.answer = switch answer {
        case .text(let text): request.kind == .secret ? String(repeating: "•", count: 8) : text
        case .number(let number): number.formatted()
        case .bool(let flag):
            // A yes or no about a saved secret reads as what it decided.
            if request.secretName != nil { flag ? "Allowed" : "Not allowed" } else { flag ? "Yes" : "No" }
        case .file(let url): url.lastPathComponent
        case .form(let values):
            request.fields
                .map { "\($0.label): \($0.describe(values[$0.id] ?? .none))" }
                .joined(separator: " · ")
        case .cancelled: "Cancelled"
        }
        if case .form(let values) = answer {
            questions[request.id]?.formValues = values
            // What was just entered is the thing to look at next.
            if followsNewest { selectedArtifact = .form(request.id) }
        }
        // Settled right away, so the question's controls go at the click
        // instead of when the engine reports back.
        questions[request.id]?.isPending = false
        request.reply(answer)
    }

    func apply(_ event: RunEvent) {
        switch event {
        case .runStarted(let info):
            runs.append(info)
        case .runFinished:
            break
        case .log(let entry):
            entries.append(.log(entry))
        case .spanStarted(let span):
            spans[span.id] = span
            entries.append(.span(span.id))
        case .spanFinished(let span):
            spans[span.id] = span
        case .file(let saved):
            // The same file arrives again when the script names it.
            if knownFiles.insert(saved.id).inserted {
                entries.append(.file(id: saved.id, runID: saved.runID, url: saved.url, date: saved.date))
            }
            if !files.contains(saved.url) { files.append(saved.url) }
            fileNames[saved.url] = saved.name
        case .output(let value):
            // The same value arrives again when the script names it.
            if outputs[value.id] == nil {
                entries.append(.output(value.id))
                // Like a playground: what the script just produced is what is on show.
                if followsNewest { selectedArtifact = .output(value.id) }
            }
            outputs[value.id] = value
        case .prompt(let request):
            questions[request.id] = Question(request: request)
            entries.append(.question(request.id))
        case .promptResolved(let id):
            questions[id]?.isPending = false
        case .notification(let notification):
            entries.append(.notification(notification))
        }
    }

    func complete(_ summary: RunSummary) {
        for id in questions.keys { questions[id]?.isPending = false }
        self.summary = summary
        // The last thing the script published is what to look at when it is done.
        if followsNewest, summary.error == nil, let last = outputIDs.last {
            selectedArtifact = .output(last)
        }
    }
}
