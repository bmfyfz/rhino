import Foundation

/// A finished run as it can be kept: everything it logged, called, asked,
/// wrote and published, in the order it happened. An app stores the encoded
/// form wherever it keeps its history, and reads it back to show the run again.
public struct RunRecord: Identifiable, Codable, Sendable {
    /// A question that was asked, and how it was answered.
    public struct Question: Identifiable, Hashable, Codable, Sendable {
        public var id: UUID
        public var runID: String
        public var message: String
        public var kind: PromptRequest.Kind
        /// The fields of a form. Empty for every other kind.
        public var fields: [FormField]
        public var detail: String
        public var askedAt: Date
        /// The answer as it was shown; a secret's is already dots.
        public var answer: String?
        /// For a submitted form: the value of each field.
        public var formValues: [String: FormValue]?

        public init(request: PromptRequest, askedAt: Date, answer: String?, formValues: [String: FormValue]?) {
            id = request.id
            runID = request.runID
            message = request.message
            kind = request.kind
            fields = request.fields
            detail = request.detail
            self.askedAt = askedAt
            self.answer = answer
            self.formValues = formValues
        }
    }

    public enum Item: Hashable, Codable, Sendable {
        case log(LogEntry)
        case call(HTTPSpan)
        case file(SavedFile)
        case question(Question)
        case output(OutputValue)
        case notification(RunNotification)
    }

    /// The longest request or response body kept with a call. A run on screen
    /// shows more; history is for seeing what happened, not for archiving.
    public static let maxStoredBody = 64 * 1024

    public var id: UUID
    /// The id of the script that was run.
    public var script: String
    /// Something other than the user started it, so nobody was there to
    /// answer questions.
    public var isScheduled: Bool
    /// What started it: "schedule", "folder", "shortcut". Nil for the user,
    /// and in records from before this was kept.
    public var trigger: String?
    public var summary: RunSummary
    /// The script's own run and the runs of the scripts it chained.
    public var runs: [RunInfo]
    public var items: [Item]

    public init(id: UUID, script: String, isScheduled: Bool, trigger: String? = nil, summary: RunSummary, runs: [RunInfo], items: [Item]) {
        self.id = id
        self.script = script
        self.isScheduled = isScheduled
        self.trigger = trigger
        self.summary = summary
        self.runs = runs
        self.items = items
    }

    private enum CodingKeys: String, CodingKey {
        case id, script = "module", isScheduled, trigger, summary, runs, items
    }

    public var startedAt: Date { summary.startedAt }
    public var failed: Bool { summary.error != nil }

    /// The record as data to store, with long HTTP bodies cut short.
    public func encoded() throws -> Data {
        var copy = self
        copy.items = items.map { item in
            guard case .call(var span) = item else { return item }
            span.requestBody = span.requestBody.map(Self.shortened)
            span.responseBody = span.responseBody.map(Self.shortened)
            return .call(span)
        }
        return try JSONEncoder().encode(copy)
    }

    public init(data: Data) throws {
        self = try JSONDecoder().decode(RunRecord.self, from: data)
    }

    private static func shortened(_ body: String) -> String {
        guard body.utf8.count > maxStoredBody else { return body }
        return String(body.prefix(maxStoredBody)) + "\n… truncated"
    }
}

/// Where finished runs are kept, as far as scripts need to know: one script
/// can look at what another last produced without running it again.
public protocol RunArchive: Sendable {
    /// The most recent run of a script that ended without an error; nil if
    /// there is none.
    func latestSuccessfulRun(of script: String) async -> RunRecord?
}

extension PromptRequest {
    /// A question from a stored run. It was settled long ago, so replying
    /// does nothing.
    public init(_ question: RunRecord.Question) {
        self.init(
            id: question.id,
            runID: question.runID,
            message: question.message,
            kind: question.kind,
            options: [],
            placeholder: "",
            defaultText: nil,
            fields: question.fields,
            detail: question.detail,
            submitLabel: "",
            secretName: nil,
            reply: { _ in }
        )
    }
}
