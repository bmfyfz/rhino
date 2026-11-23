import ArgumentParser
import Foundation
import RhinoControl

/// The `rhino` command: manages and runs the scripts in the Rhino app from
/// a terminal, for people and for coding agents alike.
public struct RhinoCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "rhino",
        abstract: "Manage and run the scripts in the Rhino app.",
        discussion: """
        Every command talks to the Rhino app on this Mac, which does the work: \
        runs show up in its window and its history, and its rules about \
        approval and secrets apply. The app is opened if it is not running. \
        Turn the tool on once in Rhino under Settings > General.

        A SCRIPT is named by its id (`reports/monthly`), its title \
        ("Monthly report"), or its file name when no other script shares it.

        Add --json to a command to get data instead of text. `rhino run` \
        prints what the script returned on standard output and its log on \
        standard error, so `rhino run x > result.json` keeps only the result.

        Exit codes: 0 it worked · 1 it did not (the script failed, the name \
        is unknown, you said no) · 2 Rhino could not be reached · 64 the \
        command was not written correctly.
        """,
        version: ControlProtocol.toolVersion,
        subcommands: [
            Status.self, List.self, Show.self, New.self, Write.self, Check.self,
            Run.self, Stop.self, Runs.self, Log.self,
            Move.self, Remove.self, Open.self,
            API.self, Functions.self, Secrets.self, Schedules.self,
        ]
    )

    public init() {}
}

struct Format: ParsableArguments {
    @Flag(name: .long, help: "Print JSON instead of text.")
    var json = false
}

// MARK: - Looking

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "What Rhino is doing: running scripts, schedules, watched folders.")
    @OptionGroup var format: Format

    func run() throws {
        guard case .status(let status) = try Session.perform(.status) else { return }
        try format.json ? Terminal.json(status) : Terminal.out(Render.status(status))
    }
}

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List the scripts.", aliases: ["ls"])
    @OptionGroup var format: Format

    func run() throws {
        guard case .scripts(let scripts) = try Session.perform(.list) else { return }
        try format.json ? Terminal.json(scripts) : Terminal.out(Render.scripts(scripts))
    }
}

struct Show: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print a script's source.", aliases: ["cat"])
    @Argument(help: "The script.") var script: String
    @OptionGroup var format: Format

    func run() throws {
        guard case .script(let info, let source) = try Session.perform(.show(script: script)) else { return }
        if format.json {
            struct Shown: Encodable {
                let script: ScriptInfo
                let source: String
            }
            try Terminal.json(Shown(script: info, source: source))
        } else {
            Terminal.out(source)
        }
    }
}

struct API: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "api",
        abstract: "Print the reference of everything a script can use.",
        discussion: "Read this before writing a script: it is the same reference the app's own AI writer is given."
    )

    func run() throws {
        guard case .text(let reference) = try Session.perform(.api) else { return }
        Terminal.out(reference)
    }
}

// MARK: - Writing

struct New: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create a script.",
        discussion: "The source comes from FILE or from what is piped in. With neither, the script starts from Rhino's template."
    )
    @Argument(help: "What to call it.") var name: String
    @Argument(help: "A file with its source, or - for standard input.") var file: String?
    @Option(name: .long, help: "The folder to put it in, such as reports or reports/2026.") var folder = ""
    @OptionGroup var format: Format

    func run() throws {
        let source = try Source.read(file)
        guard case .script(let info, _) = try Session.perform(.create(name: name, folder: folder, source: source)) else { return }
        try format.json ? Terminal.json(info) : Terminal.out("Created \(info.id)")
    }
}

struct Write: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Replace a script's source.",
        discussion: """
        The source comes from FILE or from what is piped in. It is refused, \
        and nothing changes, when it is not valid JavaScript. The version it \
        replaces is kept in the script's history in the app.
        """
    )
    @Argument(help: "The script.") var script: String
    @Argument(help: "A file with the new source, or - for standard input.") var file: String?
    @OptionGroup var format: Format

    func run() throws {
        let source = try Source.required(file)
        guard case .script(let info, _) = try Session.perform(.write(script: script, source: source)) else { return }
        try format.json ? Terminal.json(info) : Terminal.out("Saved \(info.id)")
    }
}

struct Check: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Read a script without running it: is it valid, and what would it touch?",
        discussion: "Checks FILE, what is piped in, or with --script a script that is already in Rhino."
    )
    @Argument(help: "A file with the source, or - for standard input.") var file: String?
    @Option(name: .long, help: "Check this script in Rhino instead of a file.") var script: String?
    @OptionGroup var format: Format

    func run() throws {
        let source = script == nil ? try Source.required(file) : nil
        guard case .check(let report) = try Session.perform(.check(source: source, script: script)) else { return }
        try format.json ? Terminal.json(report) : Terminal.out(Render.check(report))
        if report.problem != nil { throw ExitCode(Exit.failed) }
    }
}

struct Move: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mv", abstract: "Move a script into a folder.")
    @Argument(help: "The script.") var script: String
    @Argument(help: "The folder, such as reports. Use / for the top.") var folder: String

    func run() throws {
        let folder = folder == "/" ? "" : folder
        guard case .script(let info, _) = try Session.perform(.move(script: script, folder: folder)) else { return }
        Terminal.out("Moved to \(info.id)")
    }
}

struct Remove: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Move a script to the Trash.")
    @Argument(help: "The script.") var script: String

    func run() throws {
        guard case .ok(let message) = try Session.perform(.remove(script: script)) else { return }
        Terminal.out(message)
    }
}

struct Open: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Bring Rhino to the front, showing a script if one is named.")
    @Argument(help: "The script.") var script: String?

    func run() throws {
        _ = try Session.perform(.open(script: script))
    }
}

// MARK: - Running

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a script and wait for it to finish.",
        discussion: """
        Prints what the script returned as JSON on standard output, and its \
        log on standard error as it happens. Control-C stops the run.

        Nobody is at the window, so the script's questions take their \
        defaults, as on a schedule: hand it what it needs with --data, which \
        the script reads as input.data, and --file, which it gets from \
        input.file().

        The first time a script is run from here, and whenever it starts \
        reaching for something new, Rhino asks you in its window whether it \
        may run. The command waits for your answer.
        """
    )
    @Argument(help: "The script.") var script: String
    @Option(name: .long, help: "JSON the script finds in input.data. Use - to read it from standard input.") var data: String?
    @Option(name: .long, help: "A file whose content is the JSON for input.data.") var dataFile: String?
    @Option(name: .long, help: "A file to hand the script. Repeat for several.") var file: [String] = []
    @Flag(name: .shortAndLong, help: "Do not print the log, only the result.") var quiet = false
    @OptionGroup var format: Format

    func validate() throws {
        if data != nil, dataFile != nil { throw ValidationError("Give --data or --data-file, not both.") }
    }

    func run() throws {
        var input = data
        if data == "-" {
            input = Terminal.readInput()
        } else if let dataFile {
            input = try Source.required(dataFile)
        }
        let files = try file.map { path -> String in
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
                throw Exit.fail("There is no file at \(path).")
            }
            return url.path(percentEncoded: false)
        }

        let showsLog = !quiet && !format.json
        var root = script
        let result = try Session.perform(.run(script: script, data: input, files: files)) { message in
            switch message {
            case .line(let line):
                // The first line's script is the one that was asked for, by its id.
                if root == script, line.kind == .log || line.kind == .call { root = line.script }
                if showsLog { Terminal.error(Render.line(line, root: root)) }
            case .waiting(let what):
                if !format.json { Terminal.error(what) }
            case .done, .failed:
                break
            }
        }
        guard case .run(let report) = result else { return }
        if format.json {
            try Terminal.json(report)
        } else {
            if !quiet || report.run.status != .finished { Terminal.error(Render.outcome(report)) }
            if let result = report.result { Terminal.out(Render.pretty(result)) }
        }
        if report.run.status != .finished { throw ExitCode(Exit.failed) }
    }
}

struct Stop: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop a script that is running.")
    @Argument(help: "The script.") var script: String

    func run() throws {
        guard case .ok(let message) = try Session.perform(.stop(script: script)) else { return }
        Terminal.out(message)
    }
}

struct Runs: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List earlier runs, newest first.")
    @Argument(help: "Only this script's runs.") var script: String?
    @Option(name: .shortAndLong, help: "How many to list.") var limit = 10
    @OptionGroup var format: Format

    func validate() throws {
        guard (1...200).contains(limit) else { throw ValidationError("--limit is a number from 1 to 200.") }
    }

    func run() throws {
        guard case .runs(let runs) = try Session.perform(.runs(script: script, limit: limit)) else { return }
        try format.json ? Terminal.json(runs) : Terminal.out(Render.runs(runs))
    }
}

struct Log: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show one run: its log, its calls, and what it returned.",
        discussion: "Name a script for its latest run, or give a run's id from `rhino runs`."
    )
    @Argument(help: "A script, or a run's id.") var what: String
    @OptionGroup var format: Format

    func run() throws {
        let isRun = UUID(uuidString: what) != nil
        guard case .run(let report) = try Session.perform(.log(run: isRun ? what : nil, script: isRun ? nil : what)) else { return }
        try format.json ? Terminal.json(report) : Terminal.out(Render.log(report))
    }
}

// MARK: - The rest of the app

struct Secrets: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List the saved secrets by name, and which scripts may use them.",
        discussion: "Values are never shown, and secrets are added, removed and allowed only in the app."
    )
    @OptionGroup var format: Format

    func run() throws {
        guard case .secrets(let secrets) = try Session.perform(.secrets) else { return }
        try format.json ? Terminal.json(secrets) : Terminal.out(Render.secrets(secrets))
    }
}

struct Schedules: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the schedules, or pause and resume them all.",
        discussion: "A script's own schedule is the `// @schedule` line in its header; change it with `rhino write`.",
        subcommands: [ListSchedules.self, Pause.self, Resume.self],
        defaultSubcommand: ListSchedules.self
    )

    struct ListSchedules: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "Show every schedule and when it next comes due.")
        @OptionGroup var format: Format

        func run() throws {
            guard case .status(let status) = try Session.perform(.schedules(paused: nil)) else { return }
            if format.json {
                try Terminal.json(status.scheduled)
            } else if status.scheduled.isEmpty {
                Terminal.out("No script has a schedule.")
            } else {
                Terminal.out((status.schedulesPaused ? "Paused.\n" : "") + Render.table(["SCRIPT", "SCHEDULE", "NEXT"], status.scheduled.map {
                    [$0.script, $0.schedule, $0.problem ?? $0.next.map(Render.day) ?? ""]
                }))
            }
        }
    }

    struct Pause: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop scheduled runs from starting until resumed.")

        func run() throws {
            _ = try Session.perform(.schedules(paused: true))
            Terminal.out("Schedules are paused.")
        }
    }

    struct Resume: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Let scheduled runs start again.")

        func run() throws {
            _ = try Session.perform(.schedules(paused: false))
            Terminal.out("Schedules are running.")
        }
    }
}

struct Functions: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage the shared functions every script can use.",
        subcommands: [ListFunctions.self, ShowFunctions.self, WriteFunctions.self, RemoveFunctions.self],
        defaultSubcommand: ListFunctions.self
    )

    struct ListFunctions: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "List the files of shared functions and what each defines.")
        @OptionGroup var format: Format

        func run() throws {
            guard case .functions(let files) = try Session.perform(.functions) else { return }
            try format.json ? Terminal.json(files) : Terminal.out(Render.functions(files))
        }
    }

    struct ShowFunctions: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "show", abstract: "Print one file of shared functions.")
        @Argument(help: "The file's name, without .js.") var name: String

        func run() throws {
            guard case .text(let source) = try Session.perform(.showFunctions(name: name)) else { return }
            Terminal.out(source)
        }
    }

    struct WriteFunctions: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "write",
            abstract: "Create or replace a file of shared functions.",
            discussion: "The source comes from FILE or from what is piped in. It is refused when it is not valid, or defines a name that is already taken."
        )
        @Argument(help: "The file's name, without .js.") var name: String
        @Argument(help: "A file with the source, or - for standard input.") var file: String?

        func run() throws {
            let source = try Source.required(file)
            guard case .ok(let message) = try Session.perform(.writeFunctions(name: name, source: source)) else { return }
            Terminal.out(message)
        }
    }

    struct RemoveFunctions: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "rm", abstract: "Move a file of shared functions to the Trash.")
        @Argument(help: "The file's name, without .js.") var name: String

        func run() throws {
            guard case .ok(let message) = try Session.perform(.removeFunctions(name: name)) else { return }
            Terminal.out(message)
        }
    }
}
