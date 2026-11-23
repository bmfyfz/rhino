import Foundation
import Synchronization
import Testing
import RhinoCLI
import RhinoControl

/// The `rhino` tool as a terminal sees it: the real program, run against a
/// stand-in for the app, judged by what it prints where and how it exits.
@Suite struct CommandLineTests {
    private final class Marker {}

    /// The tool as it was just built, next to the tests.
    static let tool = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appending(path: "rhino")

    static let started = Date(timeIntervalSince1970: 1_800_000_000)

    struct Outcome {
        let status: Int32
        let out: String
        let error: String
    }

    /// A stand-in app that answers every request with `answer` and keeps
    /// what it was asked.
    final class App: Sendable {
        /// What the tool asked for, in order.
        final class Asked: Sendable {
            private let requests = Mutex<[ControlRequest]>([])
            func add(_ request: ControlRequest) { requests.withLock { $0.append(request) } }
            var all: [ControlRequest] { requests.withLock { $0 } }
        }

        let path = "/tmp/rhino-cli-\(UUID().uuidString.prefix(8)).sock"
        let asked = Asked()
        private let listener: ControlListener

        init(_ answer: @escaping @Sendable (ControlRequest, ControlConnection) -> Void) throws {
            let asked = asked
            listener = try ControlListener(path: path) { request, connection in
                asked.add(request)
                answer(request, connection)
            }
        }

        deinit {
            listener.stop()
        }

        func rhino(_ arguments: String..., input: String? = nil) throws -> Outcome {
            let process = Process()
            process.executableURL = CommandLineTests.tool
            process.arguments = arguments
            process.environment = ["RHINO_SOCKET": path, "TZ": "UTC"]
            let (out, error, stdin) = (Pipe(), Pipe(), Pipe())
            process.standardOutput = out
            process.standardError = error
            process.standardInput = stdin
            try process.run()
            if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
            try stdin.fileHandleForWriting.close()
            let printed = out.fileHandleForReading.readDataToEndOfFile()
            let complained = error.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Outcome(status: process.terminationStatus, out: String(decoding: printed, as: UTF8.self), error: String(decoding: complained, as: UTF8.self))
        }
    }

    static func report(_ status: RunBrief.Status, error: RunReport.Failure? = nil) -> RunReport {
        RunReport(
            run: RunBrief(id: "6F9619FF-8B86-D011-B42D-00C04FC964FF", script: "site-check", startedAt: started, duration: 1.25, status: status, trigger: "commandLine", error: error?.message),
            result: status == .finished ? .object(["up": .integer(3), "sites": .array([.string("a"), .string("b")])]) : nil,
            error: error,
            files: [RunReport.File(name: "Report", path: "/tmp/report.csv", bytes: 120)],
            log: [RunLine(time: started, script: "site-check", kind: .log, text: "Checking 3 sites", level: "info")]
        )
    }

    @Test func listsScriptsAsATableOrAsData() throws {
        let app = try App { _, connection in
            connection.send(.done(.scripts([
                ScriptInfo(id: "site-check", name: "Site check", schedule: "every 15 minutes", lastRun: RunBrief(id: "r", script: "site-check", startedAt: Self.started, status: .finished)),
                ScriptInfo(id: "AI/sort-feedback", name: "Sort feedback", needsApproval: true),
            ])))
        }
        let listed = try app.rhino("list")
        #expect(listed.status == 0)
        #expect(listed.out == """
        NAME           ID                RUNS              LAST RUN                   STATE
        Site check     site-check        every 15 minutes  finished 2027-01-15 08:00
        Sort feedback  AI/sort-feedback                                               needs approval

        """)
        #expect(listed.error.isEmpty)

        // `ls` is the same command, and --json gives the answer itself.
        let data = try app.rhino("ls", "--json")
        let scripts = try JSONSerialization.jsonObject(with: Data(data.out.utf8)) as? [[String: Any]]
        #expect(scripts?.map { $0["id"] as? String } == ["site-check", "AI/sort-feedback"])
        #expect((scripts?.first?["lastRun"] as? [String: Any])?["startedAt"] as? String == "2027-01-15T08:00:00Z")
        #expect(app.asked.all == [.list, .list])
    }

    @Test func aRunPrintsItsResultOnOutputAndItsLogOnError() throws {
        let app = try App { _, connection in
            connection.send(.waiting("Waiting for you to approve “Site check” in Rhino…"))
            connection.send(.line(RunLine(time: Self.started, script: "site-check", kind: .log, text: "Checking 3 sites", level: "info")))
            connection.send(.line(RunLine(time: Self.started, script: "helper", kind: .call, text: "GET 200 https://example.com 12 ms")))
            connection.send(.line(RunLine(time: Self.started, script: "site-check", kind: .file, text: "Report  /tmp/report.csv")))
            connection.send(.done(.run(Self.report(.finished))))
        }
        let ran = try app.rhino("run", "Site check", "--data", #"{"only":"a"}"#, "--file", "/etc/hosts")
        #expect(ran.status == 0)
        // Only what the script returned is on standard output, so it can be piped on.
        #expect(try JSONSerialization.jsonObject(with: Data(ran.out.utf8)) as? NSDictionary == ["up": 3, "sites": ["a", "b"]])
        #expect(ran.error == """
        Waiting for you to approve “Site check” in Rhino…
        08:00:00  Checking 3 sites
        08:00:00  [helper] GET 200 https://example.com 12 ms
        08:00:00  → Report  /tmp/report.csv
        Finished in 1.2 s

        """)
        #expect(app.asked.all == [.run(script: "Site check", data: #"{"only":"a"}"#, files: ["/etc/hosts"])])

        // --quiet leaves only the result; --json gives the whole run and nothing else.
        let quiet = try app.rhino("run", "Site check", "-q")
        #expect(quiet.error == "Waiting for you to approve “Site check” in Rhino…\n")
        let whole = try app.rhino("run", "Site check", "--json")
        #expect(whole.error.isEmpty)
        let run = try JSONSerialization.jsonObject(with: Data(whole.out.utf8)) as? [String: Any]
        #expect((run?["run"] as? [String: Any])?["status"] as? String == "finished")
        #expect((run?["files"] as? [[String: Any]])?.first?["path"] as? String == "/tmp/report.csv")
    }

    @Test func aFailedRunSaysWhyAndExitsWithOne() throws {
        let failure = RunReport.Failure(name: "Error", message: "no data today", script: "site-check", line: 3)
        let app = try App { _, connection in connection.send(.done(.run(Self.report(.failed, error: failure)))) }

        let ran = try app.rhino("run", "site-check")
        #expect(ran.status == 1)
        #expect(ran.out.isEmpty)
        #expect(ran.error == "Failed in 1.2 s: Error: no data today (site-check.js, line 3)\n")
        // Quiet still says why it failed.
        #expect(try app.rhino("run", "site-check", "--quiet").error.contains("no data today"))
        // As data, the failure is in the document, and the exit code still says it failed.
        let whole = try app.rhino("run", "site-check", "--json")
        #expect(whole.status == 1)
        #expect(whole.out.contains(#""message" : "no data today""#))
    }

    @Test func whatTheAppRefusesIsSaidPlainly() throws {
        let app = try App { _, connection in connection.send(.failed("No script is called “nope”. `rhino list` shows them.")) }
        let shown = try app.rhino("show", "nope")
        #expect(shown.status == 1)
        #expect(shown.out.isEmpty)
        #expect(shown.error == "rhino: No script is called “nope”. `rhino list` shows them.\n")
    }

    @Test func nothingListeningExitsWithTwo() throws {
        let app = try App { _, connection in connection.send(.done(.ok(""))) }
        let process = Process()
        process.executableURL = Self.tool
        process.arguments = ["status"]
        process.environment = ["RHINO_SOCKET": app.path + ".gone"]
        let error = Pipe()
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 2)
        #expect(String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).hasPrefix("rhino: Nothing is answering"))
    }

    @Test func sourceComesFromAFileOrFromAPipe() throws {
        let app = try App { request, connection in
            switch request {
            case .write(let script, _): connection.send(.done(.script(ScriptInfo(id: script, name: "X"), source: "")))
            case .create(let name, _, _): connection.send(.done(.script(ScriptInfo(id: "reports/" + name.lowercased(), name: name), source: "")))
            case .check: connection.send(.done(.check(CheckReport(problem: "Unexpected token '}' on line 2"))))
            default: connection.send(.failed("unexpected"))
            }
        }
        let file = FileManager.default.temporaryDirectory.appending(path: "rhino-cli-\(UUID().uuidString).js")
        try "output.log('from a file');\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(try app.rhino("write", "site-check", input: "output.log('piped');\n").out == "Saved site-check\n")
        #expect(try app.rhino("write", "site-check", file.path(percentEncoded: false)).status == 0)
        #expect(try app.rhino("new", "Monthly", "--folder", "reports", "-", input: "1;").out == "Created reports/monthly\n")
        // A check that finds a mistake prints it and exits with one.
        let checked = try app.rhino("check", input: "}{")
        #expect(checked.status == 1)
        #expect(checked.out == "Not valid JavaScript: Unexpected token '}' on line 2\n")

        #expect(app.asked.all == [
            .write(script: "site-check", source: "output.log('piped');\n"),
            .write(script: "site-check", source: "output.log('from a file');\n"),
            .create(name: "Monthly", folder: "reports", source: "1;"),
            .check(source: "}{", script: nil),
        ])
        // A file that is not there never reaches the app.
        let missing = try app.rhino("write", "site-check", "/nowhere/at/all.js")
        #expect(missing.status == 1)
        #expect(missing.error == "rhino: Could not read /nowhere/at/all.js.\n")
    }

    @Test func aRunIdAndAScriptNameAreToldApart() throws {
        let app = try App { _, connection in connection.send(.done(.run(Self.report(.finished)))) }
        let logged = try app.rhino("log", "6F9619FF-8B86-D011-B42D-00C04FC964FF")
        #expect(logged.out.hasPrefix("site-check · 2027-01-15 08:00 · started by command line · run 6F9619FF-8B86-D011-B42D-00C04FC964FF\n08:00:00  Checking 3 sites\nFinished in 1.2 s\n\n{"))
        _ = try app.rhino("log", "Site check")
        #expect(app.asked.all == [
            .log(run: "6F9619FF-8B86-D011-B42D-00C04FC964FF", script: nil),
            .log(run: nil, script: "Site check"),
        ])
    }

    @Test func mistakesInTheCommandAreUsageErrors() throws {
        let app = try App { _, connection in connection.send(.done(.ok(""))) }
        #expect(try app.rhino("run").status == 64)
        #expect(try app.rhino("run", "x", "--data", "1", "--data-file", "f").status == 64)
        #expect(try app.rhino("frobnicate").status == 64)
        #expect(app.asked.all.isEmpty)
        #expect(try app.rhino("--version").out == "\(ControlProtocol.toolVersion)\n")
    }

    @Test func textIsLaidOutPlainly() {
        #expect(Render.table(["A", "LONGER"], [["one", "x"], ["three", ""]]) == "A      LONGER\none    x\nthree")
        #expect(Render.took(0.0421) == "42 ms")
        #expect(Render.took(8.04) == "8.0 s")
        #expect(Render.took(125) == "2 min 5 s")
        #expect(Render.check(CheckReport(touches: ["Contact api.github.com"], unapproved: ["Contact api.github.com"])) == """
        Valid JavaScript.
        When it runs, it will:
          Contact api.github.com
        Not agreed to yet, so Rhino will ask before it runs from here:
          Contact api.github.com
        """)
        #expect(Render.secrets([SecretInfo(name: "GITHUB_TOKEN", scripts: ["a", "b"]), SecretInfo(name: "X", scripts: [])]) == "NAME          USED BY\nGITHUB_TOKEN  a, b\nX             no script yet")
    }
}
