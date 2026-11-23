import Foundation

// What the `rhino` command line tool and the app say to each other.
//
// The tool does no work of its own. It sends the app one request over a
// socket only the user can open; the app does the work with the engine,
// history and Keychain it already has, and answers with messages: lines of a
// run as they happen, then one result or one failure. Every request is its
// own connection, and closing it early calls off what was asked for.

public enum ControlProtocol {
    /// Goes up when a request or an answer changes its meaning.
    public static let version = 1

    /// The version of the tool and of the app it ships in. Keep in step with
    /// MARKETING_VERSION in project.yml.
    public static let toolVersion = "0.1.0"

    public static let bundleIdentifier = "app.rhino.Rhino"

    /// The app's preference that says whether the tool may control it.
    public static let enabledKey = "commandLineControl"

    /// Where the app listens. `RHINO_SOCKET` names another place, for tests.
    public static var socketPath: String {
        if let other = ProcessInfo.processInfo.environment["RHINO_SOCKET"], !other.isEmpty { return other }
        return URL.applicationSupportDirectory.appending(path: "Rhino/control.sock").path(percentEncoded: false)
    }
}

/// One request, with the version of the protocol it was written for.
public struct ControlEnvelope: Codable, Sendable {
    public var version: Int
    public var request: ControlRequest

    public init(_ request: ControlRequest, version: Int = ControlProtocol.version) {
        self.version = version
        self.request = request
    }
}

/// Everything the tool can ask of the app. A `script` is named the way
/// `run()` names one: its id, its title, or its file name when that is unique.
public enum ControlRequest: Codable, Equatable, Sendable {
    case status
    case list
    case show(script: String)
    case create(name: String, folder: String, source: String?)
    case write(script: String, source: String)
    case remove(script: String)
    case move(script: String, folder: String)
    /// Reads code without running or saving it. One of the two is given.
    case check(source: String?, script: String?)
    case run(script: String, data: String?, files: [String])
    case stop(script: String)
    case runs(script: String?, limit: Int)
    /// One run by its id, or the latest run of a script.
    case log(run: String?, script: String?)
    case open(script: String?)
    case api
    case secrets
    case functions
    case showFunctions(name: String)
    case writeFunctions(name: String, source: String)
    case removeFunctions(name: String)
    case schedules(paused: Bool?)
}

/// What the app sends back, one message per line.
public enum ControlMessage: Codable, Equatable, Sendable {
    /// Something a run did, sent while it is still going.
    case line(RunLine)
    /// The app is waiting for the person, and says for what.
    case waiting(String)
    /// The last message of a request that worked.
    case done(ControlResult)
    /// The last message of a request that did not.
    case failed(String)
}

public enum ControlResult: Codable, Equatable, Sendable {
    case ok(String)
    case status(StatusReport)
    case scripts([ScriptInfo])
    case script(ScriptInfo, source: String)
    case check(CheckReport)
    case run(RunReport)
    case runs([RunBrief])
    case text(String)
    case secrets([SecretInfo])
    case functions([FunctionsInfo])
}

// MARK: - What the answers are made of

/// A script as a list shows it.
public struct ScriptInfo: Codable, Equatable, Sendable {
    /// Its place below the scripts folder, without ".js".
    public var id: String
    public var name: String
    public var description: String?
    public var folder: String
    public var schedule: String?
    public var watch: String?
    public var key: String?
    public var path: String
    public var running: Bool
    /// When its schedule next comes due.
    public var nextRun: Date?
    public var lastRun: RunBrief?
    /// It reaches for something nobody has agreed to yet, so running it
    /// from the command line makes the app ask first.
    public var needsApproval: Bool

    public init(id: String, name: String, description: String? = nil, folder: String = "", schedule: String? = nil, watch: String? = nil, key: String? = nil, path: String = "", running: Bool = false, nextRun: Date? = nil, lastRun: RunBrief? = nil, needsApproval: Bool = false) {
        self.id = id
        self.name = name
        self.description = description
        self.folder = folder
        self.schedule = schedule
        self.watch = watch
        self.key = key
        self.path = path
        self.running = running
        self.nextRun = nextRun
        self.lastRun = lastRun
        self.needsApproval = needsApproval
    }
}

/// One run in a line: which, when, and how it ended.
public struct RunBrief: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case running, finished, failed, stopped
    }

    public var id: String
    public var script: String
    public var startedAt: Date
    /// In seconds. Nil while it runs.
    public var duration: Double?
    public var status: Status
    /// What started it: "manual", "schedule", "folder", "shortcut", "commandLine".
    public var trigger: String?
    public var error: String?

    public init(id: String, script: String, startedAt: Date, duration: Double? = nil, status: Status, trigger: String? = nil, error: String? = nil) {
        self.id = id
        self.script = script
        self.startedAt = startedAt
        self.duration = duration
        self.status = status
        self.trigger = trigger
        self.error = error
    }
}

/// One thing a run did: a log line, an HTTP call, something published, a
/// file saved, a notification, a question.
public struct RunLine: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case log, call, output, file, notification, question
    }

    public var time: Date
    /// The script it came from, which matters when one script runs another.
    public var script: String
    public var kind: Kind
    /// What to show for it.
    public var text: String
    /// For a log line: "debug", "info", "warn" or "error".
    public var level: String?
    /// For a call.
    public var method: String?
    public var url: String?
    public var status: Int?
    public var milliseconds: Int?
    /// For a file: where it is.
    public var path: String?

    public init(time: Date, script: String, kind: Kind, text: String, level: String? = nil, method: String? = nil, url: String? = nil, status: Int? = nil, milliseconds: Int? = nil, path: String? = nil) {
        self.time = time
        self.script = script
        self.kind = kind
        self.text = text
        self.level = level
        self.method = method
        self.url = url
        self.status = status
        self.milliseconds = milliseconds
        self.path = path
    }
}

/// A whole run: how it ended, what it returned, published and saved, and
/// its log.
public struct RunReport: Codable, Equatable, Sendable {
    public struct Failure: Codable, Equatable, Sendable {
        public var name: String
        public var message: String
        public var script: String?
        public var line: Int?

        public init(name: String, message: String, script: String? = nil, line: Int? = nil) {
            self.name = name
            self.message = message
            self.script = script
            self.line = line
        }
    }

    public struct Output: Codable, Equatable, Sendable {
        public var name: String
        /// "json", "table", "chart", "image" or "text".
        public var kind: String
        public var value: JSONValue

        public init(name: String, kind: String, value: JSONValue) {
            self.name = name
            self.kind = kind
            self.value = value
        }
    }

    public struct File: Codable, Equatable, Sendable {
        public var name: String
        public var path: String
        public var bytes: Int

        public init(name: String, path: String, bytes: Int) {
            self.name = name
            self.path = path
            self.bytes = bytes
        }
    }

    public var run: RunBrief
    /// What the script gave `output.json()` last, or returned.
    public var result: JSONValue?
    public var error: Failure?
    public var outputs: [Output]
    public var files: [File]
    public var log: [RunLine]

    public init(run: RunBrief, result: JSONValue? = nil, error: Failure? = nil, outputs: [Output] = [], files: [File] = [], log: [RunLine] = []) {
        self.run = run
        self.result = result
        self.error = error
        self.outputs = outputs
        self.files = files
        self.log = log
    }
}

/// What reading a script's code found, without running it.
public struct CheckReport: Codable, Equatable, Sendable {
    /// Why it is not valid JavaScript. Nil when it is.
    public var problem: String?
    /// What it reaches for outside itself, in words.
    public var touches: [String]
    /// Which of those nobody has agreed to yet. Empty for code that is not a saved script.
    public var unapproved: [String]

    public init(problem: String? = nil, touches: [String] = [], unapproved: [String] = []) {
        self.problem = problem
        self.touches = touches
        self.unapproved = unapproved
    }
}

public struct StatusReport: Codable, Equatable, Sendable {
    public struct Scheduled: Codable, Equatable, Sendable {
        public var script: String
        public var schedule: String
        public var next: Date?
        /// Why the schedule cannot be followed, when it cannot.
        public var problem: String?

        public init(script: String, schedule: String, next: Date? = nil, problem: String? = nil) {
            self.script = script
            self.schedule = schedule
            self.next = next
            self.problem = problem
        }
    }

    public struct Watched: Codable, Equatable, Sendable {
        public var script: String
        public var folder: String
        public var problem: String?

        public init(script: String, folder: String, problem: String? = nil) {
            self.script = script
            self.folder = folder
            self.problem = problem
        }
    }

    public var version: String
    public var scripts: Int
    public var running: [RunBrief]
    public var scheduled: [Scheduled]
    public var watched: [Watched]
    public var schedulesPaused: Bool
    /// Scripts waiting for the person to say they may run.
    public var awaitingApproval: [String]

    public init(version: String, scripts: Int, running: [RunBrief] = [], scheduled: [Scheduled] = [], watched: [Watched] = [], schedulesPaused: Bool = false, awaitingApproval: [String] = []) {
        self.version = version
        self.scripts = scripts
        self.running = running
        self.scheduled = scheduled
        self.watched = watched
        self.schedulesPaused = schedulesPaused
        self.awaitingApproval = awaitingApproval
    }
}

/// A saved secret by name, never by value.
public struct SecretInfo: Codable, Equatable, Sendable {
    public var name: String
    /// The scripts that may use it.
    public var scripts: [String]

    public init(name: String, scripts: [String]) {
        self.name = name
        self.scripts = scripts
    }
}

/// One file of shared functions.
public struct FunctionsInfo: Codable, Equatable, Sendable {
    public var name: String
    /// What it defines for every script.
    public var defines: [String]
    public var problem: String?

    public init(name: String, defines: [String], problem: String? = nil) {
        self.name = name
        self.defines = defines
        self.problem = problem
    }
}

// MARK: - Any JSON

/// A JSON value of any shape, so that what a script returned travels as
/// data and not as text holding data.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Reads JSON text. Nil when it is not JSON.
    public init?(json text: String) {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { return nil }
        self = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - On the wire

enum Wire {
    /// One message per line, so a line is never broken by the JSON in it.
    static func line<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: line)
    }
}
