import Foundation
import Testing
@testable import RhinoCore

/// The user's shared functions: defined once, usable in every script.
@Suite struct SharedFunctionTests {
    struct Files: SharedFunctionProvider {
        var files: [SharedFile]
        func sharedFiles() -> [SharedFile] { files }
    }

    static let dates = SharedFile(id: "dates", source: """
    // Turns a date into "5 March 2026".
    function longDate(date, locale = "en-GB") {
      return new Date(date).toLocaleDateString(locale, { day: "numeric", month: "long", year: "numeric", timeZone: "UTC" });
    }

    const WEEK = 7 * 86400000;

    /** Fetches the users and says so in the log. */
    async function loadUsers() {
      output.log("Loading users");
      return (await get("https://example.test/users")).data;
    }
    """)

    static let text = SharedFile(id: "text", source: """
    const shout = (words) => words.toUpperCase() + "!";
    // Uses a function from the file before this one.
    function stamped(words) { return `${shout(words)} (${longDate("2026-03-05")})`; }
    class Counter { constructor() { this.n = 0; } next() { return ++this.n; } }
    """)

    private func run(_ sources: [String: String], shared: [SharedFile], id: String = "m") async -> (summary: RunSummary, recorder: Recorder) {
        let engine = Engine(
            provider: Scripts(sources: sources),
            runsDirectory: FileManager.default.temporaryDirectory.appending(path: "rhino-tests-\(UUID().uuidString)"),
            session: stubbedSession(),
            shared: Files(files: shared)
        )
        let recorder = Recorder()
        let summary = await engine.run(id, events: recorder.record)
        return (summary, recorder)
    }

    @Test func everyScriptCanUseThem() async throws {
        let (summary, recorder) = await run(["m": """
        const users = await loadUsers();
        const counter = new Counter();
        counter.next();
        output.json({ date: longDate("2026-03-05"), week: WEEK, users: users.length, text: stamped("hi"), count: counter.next() });
        """], shared: [Self.dates, Self.text])

        #expect(summary.error == nil)
        let result = try #require(try json(summary.resultJSON) as? [String: Any])
        #expect(result["date"] as? String == "5 March 2026")
        #expect(result["week"] as? Int == 604_800_000)
        #expect(result["users"] as? Int == 2)
        #expect(result["text"] as? String == "HI! (5 March 2026)")
        #expect(result["count"] as? Int == 2)
        // What a shared function logs and fetches counts as the script's own doing.
        #expect(recorder.logs == ["Loading users"])
        #expect(recorder.finishedSpans.count == 1)
    }

    @Test func aChainedScriptGetsThemTooAndAScriptMayReuseAName() async throws {
        let (summary, recorder) = await run([
            "m": #"const inner = await run("child"); const longDate = () => "mine"; output.json({ inner, own: longDate() });"#,
            "child": #"output.log("child says", shout("hey")); output.json(longDate("2026-01-02"));"#,
        ], shared: [Self.dates, Self.text])

        #expect(summary.error == nil)
        let result = try #require(try json(summary.resultJSON) as? [String: String])
        #expect(result == ["inner": "2 January 2026", "own": "mine"])
        // The chained script's log line belongs to the chained run.
        let child = try #require(recorder.runs.first { $0.script == "child" })
        #expect(recorder.events.contains { if case .log(let entry) = $0 { entry.runID == child.id && entry.message == "child says HEY!" } else { false } })
    }

    @Test func anErrorInsideOneSaysWhere() async throws {
        let broken = SharedFile(id: "risky", source: "function risky() {\n  throw new Error('went wrong inside');\n}")
        let (summary, _) = await run(["m": "output.log('before');\nrisky();"], shared: [broken])
        #expect(summary.error?.message == "went wrong inside")
        #expect(summary.error?.script == "Shared functions/risky")
        #expect(summary.error?.line == 2)
    }

    @Test func aFileThatDoesNotParseStopsEveryRunAndSaysWhy() async throws {
        let broken = SharedFile(id: "oops", source: "function fine() {}\nconst half = ;\n")
        let (summary, recorder) = await run(["m": "output.log('never');"], shared: [Self.dates, broken])
        let message = try #require(summary.error?.message)
        #expect(message.hasPrefix("Your shared functions in “oops” have a mistake: SyntaxError"))
        #expect(message.hasSuffix("Fix it in Settings, under Functions."))
        #expect(message.contains("(line 2)"))
        #expect(recorder.logs.isEmpty)
    }

    @Test func findsWhatAFileDefines() {
        #expect(SharedLibrary.names(definedIn: Self.dates.source) == ["longDate", "WEEK", "loadUsers"])
        #expect(SharedLibrary.names(definedIn: Self.text.source) == ["shout", "stamped", "Counter"])
        // Only what starts a line counts: helpers inside a function stay private.
        #expect(SharedLibrary.names(definedIn: "function outer() {\n  function inner() {}\n  const local = 1;\n}\n  const indented = 2;") == ["outer"])
        #expect(SharedLibrary.names(definedIn: "function* each() {}\nasync function later() {}\nlet a = 1;\nvar b = 2;\nfunction each() {}") == ["each", "later", "a", "b"])

        let signatures = SharedLibrary.signatures(in: Self.dates.source + "\n" + Self.text.source)
        #expect(signatures.map(\.name) == ["longDate", "loadUsers", "shout", "stamped"])
        #expect(signatures[0].parameters == "date, locale = \"en-GB\"")
        #expect(signatures[0].comment == "Turns a date into \"5 March 2026\".")
        #expect(signatures[1].comment == "Fetches the users and says so in the log.")
        #expect(signatures[2].parameters == "words")
        #expect(signatures[3].comment == "Uses a function from the file before this one.")
    }

    @Test func saysWhatIsWrongWithAFileBeforeItIsUsed() {
        #expect(SharedLibrary.problem(in: Self.dates) == nil)
        #expect(SharedLibrary.problem(in: Self.text, among: [Self.dates, Self.text]) == nil)

        let builtIn = SharedFile(id: "a", source: "function get(url) {}")
        #expect(SharedLibrary.problem(in: builtIn) == "“get” is the name of something built in. Call yours something else.")
        let twice = SharedFile(id: "b", source: "const WEEK = 7;")
        #expect(SharedLibrary.problem(in: twice, among: [Self.dates, twice]) == "“WEEK” is already defined in dates. A name can only be defined once.")
        let broken = SharedFile(id: "c", source: "function ok() {}\nconst x = ;")
        #expect(SharedLibrary.problem(in: broken)?.contains("(line 2)") == true)
        // A file may use the API, and that is not a mistake.
        #expect(SharedLibrary.problem(in: SharedFile(id: "d", source: "function hello() { output.log('hi'); return memory.get('x'); }")) == nil)
    }

    @Test func keepsFilesInAFolder() throws {
        let library = SharedLibrary(directory: FileManager.default.temporaryDirectory.appending(path: "rhino-shared-\(UUID().uuidString)"))
        #expect(library.sharedFiles().isEmpty)

        let made = try library.create(named: "Date helpers")
        #expect(made.id == "date-helpers")
        #expect(SharedLibrary.names(definedIn: made.source) == ["dateHelpers"])
        #expect(SharedLibrary.problem(in: made) == nil)
        #expect(try library.create(named: "Date helpers").id == "date-helpers-2")

        try library.save(Self.text.source, to: "text")
        try library.save("ignored", to: ".hidden")
        // In name order, which is the order they are loaded in.
        #expect(library.sharedFiles().map(\.id) == ["date-helpers", "date-helpers-2", "text"])
        #expect(library.sharedFiles().last?.source == Self.text.source)

        try library.delete("date-helpers-2")
        #expect(library.sharedFiles().map(\.id) == ["date-helpers", "text"])
        #expect(SharedLibrary.functionName(from: "2024 report") == "helper")
    }

    @Test func theWriterIsToldWhatExists() {
        #expect(ScriptWriter.sharedSection([]) == "")
        let section = ScriptWriter.sharedSection(SharedLibrary.signatures(in: Self.dates.source))
        #expect(section.contains("- longDate(date, locale = \"en-GB\"): Turns a date into \"5 March 2026\"."))
        #expect(section.contains("- loadUsers(): Fetches the users and says so in the log."))
        // The instructions everyone shares stay as they are, so they can be cached.
        #expect(!ScriptWriter.systemPrompt.contains("longDate"))
    }
}
