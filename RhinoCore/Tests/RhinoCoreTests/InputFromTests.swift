import Foundation
import Synchronization
import Testing
@testable import RhinoCore

/// `input.from()`: reading what another script last produced.
@Suite struct InputFromTests {
    /// An archive that keeps what tests put in it, newest last.
    final class Archive: RunArchive {
        let records = Mutex<[RunRecord]>([])

        func latestSuccessfulRun(of script: String) async -> RunRecord? {
            records.withLock { $0.last { $0.script == script && !$0.failed } }
        }
    }

    /// Runs a script and files the run the way an app would.
    private func runAndArchive(_ id: String, in engine: Engine, archive: Archive, finishedAgo: TimeInterval = 0) async -> RunSummary {
        let recorder = Recorder()
        var summary = await engine.run(id, events: recorder.record)
        if finishedAgo > 0 {
            summary = RunSummary(
                error: summary.error, resultJSON: summary.resultJSON, outputDirectory: summary.outputDirectory,
                startedAt: summary.startedAt.addingTimeInterval(-finishedAgo), finishedAt: summary.finishedAt.addingTimeInterval(-finishedAgo)
            )
        }
        let items: [RunRecord.Item] = recorder.outputs.map { .output($0) } + recorder.savedFiles.map { .file($0) }
        archive.records.withLock { $0.append(RunRecord(id: UUID(), script: id, isScheduled: false, summary: summary, runs: recorder.runs, items: items)) }
        return summary
    }

    private func makeEngine(_ sources: [String: String], archive: Archive?) -> Engine {
        Engine(
            provider: Scripts(sources: sources),
            runsDirectory: FileManager.default.temporaryDirectory.appending(path: "rhino-tests-\(UUID().uuidString)"),
            session: stubbedSession(),
            archive: archive
        )
    }

    static let producer = """
    // @name Monthly sales
    output.table([{ month: "Jan", total: 10 }, { month: "Feb", total: 14 }]).name("By month");
    output.text("Up **40%**").name("Summary");
    await output.file("sales.csv", "month,total\\nJan,10\\nFeb,14\\n").name("The figures");
    output.json({ total: 24, months: 2 }).name("Totals");
    """

    static let reader = """
    const sales = await input.from("sales");
    if (!sales) { output.json("nothing yet"); return; }
    const file = sales.file("The figures");
    output.json({
      script: sales.script,
      result: sales.result,
      kinds: sales.outputs.map((item) => `${item.name}:${item.kind}`),
      totals: sales.output("totals"),
      summary: sales.output("Summary"),
      columns: sales.output("By month").columns,
      firstRow: sales.output("By month").rows[0],
      missing: sales.output("Nope") === undefined,
      fileName: file.name,
      rows: (await file.csv()).length,
      sameFile: sales.file("sales.csv") === file,
      when: !Number.isNaN(new Date(sales.finishedAt).getTime()),
    });
    """

    @Test func readsWhatAnotherScriptProducedWithoutRunningIt() async throws {
        let archive = Archive()
        let engine = makeEngine(["sales": Self.producer, "report": Self.reader], archive: archive)

        // Before the other script has ever run there is nothing, and that is not an error.
        let before = await engine.run("report", events: Recorder().record)
        #expect(try json(before.resultJSON) as? String == "nothing yet")

        _ = await runAndArchive("sales", in: engine, archive: archive)
        let recorder = Recorder()
        let summary = await engine.run("report", events: recorder.record)

        #expect(summary.error == nil)
        let read = try #require(try json(summary.resultJSON) as? [String: Any])
        #expect(read["script"] as? String == "sales")
        #expect((read["result"] as? [String: Int]) == ["total": 24, "months": 2])
        #expect(read["kinds"] as? [String] == ["By month:table", "Summary:text", "Totals:json"])
        // Names are matched whatever their case.
        #expect((read["totals"] as? [String: Int]) == ["total": 24, "months": 2])
        #expect(read["summary"] as? String == "Up **40%**")
        #expect(read["columns"] as? [String] == ["month", "total"])
        #expect(read["firstRow"] as? [String] == ["Jan", "10"])
        #expect(read["missing"] as? Bool == true)
        #expect(read["fileName"] as? String == "sales.csv")
        #expect(read["rows"] as? Int == 2)
        #expect(read["sameFile"] as? Bool == true)
        #expect(read["when"] as? Bool == true)
        // Only the reader ran: the producer was not started again.
        #expect(recorder.runs.map(\.script) == ["report"])
    }

    @Test func skipsFailedRunsAndOldOnesWhenAsked() async throws {
        let archive = Archive()
        let engine = makeEngine([
            "rates": "output.json({ eur: 1.1 });",
            "broken": "output.json('half done');\nthrow new Error('no');",
            "fresh": #"output.json((await input.from("rates", { maxAge: 60000 }))?.result ?? "too old");"#,
            "any": #"output.json((await input.from("rates"))?.result ?? "none");"#,
            "ofBroken": #"output.json((await input.from("broken")) === null);"#,
        ], archive: archive)

        _ = await runAndArchive("broken", in: engine, archive: archive)
        let ofBroken = await engine.run("ofBroken", events: Recorder().record)
        #expect(try json(ofBroken.resultJSON) as? Bool == true)

        // A run from two hours ago is there, but not fresh enough for a one-minute limit.
        _ = await runAndArchive("rates", in: engine, archive: archive, finishedAgo: 7200)
        #expect(try json(await engine.run("any", events: Recorder().record).resultJSON) as? [String: Double] == ["eur": 1.1])
        #expect(try json(await engine.run("fresh", events: Recorder().record).resultJSON) as? String == "too old")

        _ = await runAndArchive("rates", in: engine, archive: archive)
        #expect(try json(await engine.run("fresh", events: Recorder().record).resultJSON) as? [String: Double] == ["eur": 1.1])
    }

    @Test func goesStraightForOneThing() async throws {
        let archive = Archive()
        let engine = makeEngine([
            "sales": Self.producer,
            "direct": """
            const file = await input.from("sales").file("The figures");
            const first = await input.from("sales").file();
            output.json({
              rows: (await file.csv()).length,
              first: first.name,
              totals: await input.from("sales").output("Totals"),
              result: await input.from("sales").result(),
            });
            """,
            "noFile": #"await input.from("sales").file("Budget");"#,
            "noOutput": #"output.log("before");\#nawait input.from("sales").output("Forecast");"#,
            "stale": #"await input.from("sales", { maxAge: 1 }).result();"#,
        ], archive: archive)
        func message(_ id: String) async -> String { await engine.run(id, events: Recorder().record).error?.message ?? "" }

        // Asked for before the other script ever ran, each says so instead of handing back nothing.
        #expect(await message("direct") == "“sales” has not produced anything yet. Run it first.")

        _ = await runAndArchive("sales", in: engine, archive: archive, finishedAgo: 60)
        let summary = await engine.run("direct", events: Recorder().record)
        #expect(summary.error == nil)
        let read = try #require(try json(summary.resultJSON) as? [String: Any])
        #expect(read["rows"] as? Int == 2)
        #expect(read["first"] as? String == "sales.csv")
        #expect((read["totals"] as? [String: Int]) == ["total": 24, "months": 2])
        #expect((read["result"] as? [String: Int]) == ["total": 24, "months": 2])

        #expect(await message("noFile") == "The last run of “sales” saved no file called “Budget”.")
        #expect(await message("stale") == "“sales” has not produced anything recently enough. Run it first.")
        let noOutput = await engine.run("noOutput", events: Recorder().record)
        #expect(noOutput.error?.message == "The last run of “sales” published nothing called “Forecast”.")
        #expect(noOutput.error?.line == 2)
    }

    @Test func saysWhatIsWrongWithTheAsk() async throws {
        let engine = makeEngine([
            "typo": "output.log('before');\nawait input.from('No such script');",
            "blank": "await input.from('  ');",
            "alone": #"output.json((await input.from("alone")) === null);"#,
        ], archive: nil)

        let typo = await engine.run("typo", events: Recorder().record)
        #expect(typo.error?.message == "input.from(): there is no script called “No such script”.")
        #expect(typo.error?.line == 2)
        #expect(await engine.run("blank", events: Recorder().record).error?.message.contains("needs the name of a script") == true)
        // With no archive at all, nothing has been produced as far as a script can tell.
        #expect(try json(await engine.run("alone", events: Recorder().record).resultJSON) as? Bool == true)
    }

    @Test func aDeletedFileIsNotOffered() async throws {
        let archive = Archive()
        let engine = makeEngine([
            "sales": Self.producer,
            "count": #"const run = await input.from("sales"); output.json({ files: run.files.length, gone: run.file("sales.csv") === undefined });"#,
        ], archive: archive)
        let made = await runAndArchive("sales", in: engine, archive: archive)
        try FileManager.default.removeItem(at: made.outputDirectory)

        let read = try #require(try json(await engine.run("count", events: Recorder().record).resultJSON) as? [String: Any])
        #expect(read["files"] as? Int == 0)
        #expect(read["gone"] as? Bool == true)
    }
}
