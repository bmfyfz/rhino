import Foundation

/// One execution of one script. A chained `run()` call creates a child run.
public struct RunInfo: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let script: String
    public let parentID: String?
    public let startedAt: Date

    // Stored records name the script the way the first ones did.
    private enum CodingKeys: String, CodingKey {
        case id, script = "module", parentID, startedAt
    }
}

public struct RunError: Error, Hashable, Codable, Sendable {
    public var name: String
    public var message: String
    /// Script the error was thrown in, when it could be located.
    public var script: String?
    /// 1-based line inside `script`.
    public var line: Int?
    public var stack: String

    private enum CodingKeys: String, CodingKey {
        case name, message, script = "module", line, stack
    }

    /// The `name` of the error a stopped run ends with.
    public static let cancelledName = "Cancelled"

    /// Whether the run was stopped, by the user or by whoever started it,
    /// rather than failing by itself.
    public var isCancellation: Bool { name == Self.cancelledName }

    public init(name: String = "Error", message: String, script: String? = nil, line: Int? = nil, stack: String = "") {
        self.name = name
        self.message = message
        self.script = script
        self.line = line
        self.stack = stack
    }
}

public enum LogLevel: String, Codable, Sendable {
    case debug, info, warn, error
}

public struct LogEntry: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let runID: String
    public let date: Date
    public let level: LogLevel
    public let message: String
}

/// One HTTP call made by a script.
public struct HTTPSpan: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let runID: String
    public var method: String
    public var url: String
    public var startedAt: Date
    /// Nil while the request is in flight.
    public var duration: TimeInterval?
    public var status: Int?
    public var error: String?
    public var requestHeaders: [String: String]
    public var requestBody: String?
    public var responseHeaders: [String: String]
    public var responseBody: String?
    public var responseSize: Int
}

/// A question a script asked with `input.ask()`, `input.file()` or
/// `input.form()`. Call `reply` exactly once.
public struct PromptRequest: Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case text, number, secret, confirm, choice, file
        /// Several fields at once; see `fields`. Answered with `.form`.
        case form
    }

    public enum Answer: Sendable {
        case text(String)
        case number(Double)
        case bool(Bool)
        case file(URL)
        /// One value per field of a form, keyed by field id.
        case form([String: FormValue])
        case cancelled
    }

    public let id: UUID
    public let runID: String
    public let message: String
    public let kind: Kind
    /// Choices for `.choice`; allowed file extensions (may be empty) for `.file`.
    public let options: [String]
    public let placeholder: String
    public let defaultText: String?
    /// The fields of a `.form`, in display order. Empty for every other kind.
    public let fields: [FormField]
    /// A form's longer explanation, shown under its title (`message`).
    public let detail: String
    /// A form's submit button title. Empty means the default.
    public let submitLabel: String
    /// For a `.secret` asked through `secrets.get()`: the name the answer is
    /// saved under, so the user can be told it will be kept. For a `.confirm`:
    /// the saved secret a script asks to be allowed to use.
    public let secretName: String?
    public let reply: @Sendable (Answer) -> Void
}

/// Something a script published with `output.json()`, `output.image()`,
/// `output.chart()`, `output.table()` or `output.text()`.
public struct OutputValue: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case json, image, chart, table, text
    }

    public let id: UUID
    public let runID: String
    public let kind: Kind
    /// What the script called it with `.name("…")`. Nil until it does.
    public var name: String?
    /// For `.json` the value itself, indented. For the other kinds a
    /// description of what to show; see `ImageSource`, `ChartData`,
    /// `TableData` and `text`.
    public let json: String
    public let date: Date
}

/// A file a script wrote.
public struct SavedFile: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let runID: String
    public let url: URL
    /// What the script called it with `.name("…")`. Nil means its file name.
    public var name: String?
    public let date: Date

    public init(id: UUID, runID: String, url: URL, name: String? = nil, date: Date) {
        self.id = id
        self.runID = runID
        self.url = url
        self.name = name
        self.date = date
    }
}

/// A notification a script asked for with `notify()`.
public struct RunNotification: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let runID: String
    public let title: String
    /// Empty when the script gave only a title.
    public let message: String
    public let date: Date
}

public enum RunEvent: Sendable {
    case runStarted(RunInfo)
    case runFinished(runID: String, at: Date, error: RunError?, resultJSON: String?)
    case log(LogEntry)
    case spanStarted(HTTPSpan)
    case spanFinished(HTTPSpan)
    /// Sent when a file is written, and again with the same id when the
    /// script names it.
    case file(SavedFile)
    /// Sent when a value is published, and again with the same id when the
    /// script names it.
    case output(OutputValue)
    case prompt(PromptRequest)
    case promptResolved(id: UUID)
    /// The script called `notify()`; an app shows it however its platform does.
    case notification(RunNotification)
}

public struct RunSummary: Codable, Sendable {
    /// Nil when the run succeeded.
    public let error: RunError?
    /// What the root script gave `output.json()`, as pretty JSON. Nil when it set no result.
    public let resultJSON: String?
    /// Where relative `write()` calls went. Only exists if something was written.
    public let outputDirectory: URL
    public let startedAt: Date
    public let finishedAt: Date

    public var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }
}
