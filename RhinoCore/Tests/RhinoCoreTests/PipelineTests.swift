import Foundation
import Testing
@testable import RhinoCore

/// Pipelines: scripts run one after another with `run()`, each fed by the
/// one before, and `{ show: true }` to put what they publish on show.
@Suite struct PipelineTests {
    static let steps = [
        "fetch": """
        output.table([{ id: 1, paid: true }, { id: 2, paid: false }, { id: 3, paid: true }]).name("All orders");
        output.json({ orders: [{ id: 1, paid: true }, { id: 2, paid: false }, { id: 3, paid: true }], asked: input.data });
        """,
        "clean": """
        const paid = input.data.orders.filter((order) => order.paid);
        output.log(`Kept ${paid.length} paid orders`);
        output.json(paid);
        """,
        "report": """
        await output.file("report.txt", `Orders: ${input.data.map((o) => o.id).join(", ")}`).name("Report");
        output.text(`**${input.data.length}** orders`).name("Summary");
        output.json({ count: input.data.length });
        """,
        "broken": "output.log('about to fail');\nthrow new Error('no data today');",
    ]

    private func run(_ source: String, data: String? = nil) async -> (summary: RunSummary, recorder: Recorder) {
        let (engine, _) = makeEngine(Self.steps.merging(["flow": source]) { $1 })
        let recorder = Recorder()
        let summary = await engine.run("flow", data: data, events: recorder.record)
        return (summary, recorder)
    }

    static let chain = """
    const fetched = await run("fetch", input.data, { show: true });
    const paid = await run("clean", fetched, { show: true });
    return await run("report", paid, { show: true });
    """

    @Test func eachStepGetsTheResultOfTheOneBeforeAndIsOnShow() async throws {
        let (summary, recorder) = await run(Self.chain, data: #"{"since":"Monday"}"#)

        #expect(summary.error == nil)
        // The last step's result is the pipeline's.
        #expect(try json(summary.resultJSON) as? [String: Int] == ["count": 2])
        #expect(recorder.runs.map(\.script) == ["flow", "fetch", "clean", "report"])
        #expect(recorder.logs == ["Kept 2 paid orders"])

        // What the steps published is on show, each under the step that made it.
        let scriptOf = Dictionary(uniqueKeysWithValues: recorder.runs.map { ($0.id, $0.script) })
        #expect(recorder.outputs.map { "\(scriptOf[$0.runID] ?? ""):\($0.name ?? $0.kind.rawValue)" } == [
            "fetch:All orders", "fetch:json", "clean:json", "report:Summary", "report:json",
        ])
        #expect(recorder.savedFiles.map(\.name) == ["Report"])
        // The first step was handed what the pipeline was handed.
        let first = try #require(recorder.outputs.first { $0.kind == .json })
        #expect((try json(first.json) as? [String: Any])?["asked"] as? [String: String] == ["since": "Monday"])
    }

    @Test func aFailedStepStopsThePipelineAndSaysWhere() async throws {
        let (summary, recorder) = await run("""
        output.log("starting");
        const fetched = await run("fetch", null, { show: true });
        await run("broken", fetched, { show: true });
        return await run("report", fetched, { show: true });
        """)

        // The error is the step's own, at the place where it really went wrong.
        #expect(summary.error?.message == "no data today")
        #expect(summary.error?.script == "broken")
        #expect(summary.error?.line == 2)
        #expect(recorder.runs.map(\.script) == ["flow", "fetch", "broken"])
        #expect(recorder.logs == ["starting", "about to fail"])
    }

    @Test func aPlainRunKeepsItsOutputsToItself() async throws {
        for call in [#"run("fetch")"#, #"run("fetch", null, { show: false })"#, #"run("fetch", null, {})"#, #"run("fetch", null, { show: "yes" })"#] {
            let (summary, recorder) = await run("const data = await \(call); output.json(data.orders.length);")
            #expect(summary.error == nil)
            // Only what the calling script published is shown; `run()` is a function call.
            #expect(recorder.outputs.count == 1)
            #expect(try json(recorder.outputs[0].json) as? Int == 3)
        }
    }

    @Test func onlyAScriptOnShowCanPutAnotherOnShow() async throws {
        // "flow" runs "quiet" without showing it, so what "quiet" puts on
        // show stays out of sight too.
        let (engine, _) = makeEngine(Self.steps.merging([
            "flow": #"output.json(await run("quiet"));"#,
            "quiet": #"const fetched = await run("fetch", null, { show: true }); output.json(fetched.orders.length);"#,
        ]) { $1 })
        let recorder = Recorder()
        let summary = await engine.run("flow", events: recorder.record)
        #expect(summary.error == nil)
        #expect(recorder.runs.map(\.script) == ["flow", "quiet", "fetch"])
        #expect(recorder.outputs.count == 1)
        #expect(try json(recorder.outputs[0].json) as? Int == 3)
    }

    @Test func thereIsNoSeparatePipelineFunction() async throws {
        let (summary, _) = await run(#"return typeof pipeline;"#)
        #expect(try json(summary.resultJSON) as? String == "undefined")
    }

    @Test func writesAPipelineScriptThatRuns() async throws {
        let source = ScriptStore.pipeline(name: "Weekly report", steps: ["Fetch orders", "Clean \"all\" orders", "reports/build"])
        #expect(source == """
        // @name Weekly report
        // @description Runs Fetch orders, Clean "all" orders, then reports/build; each step gets the result of the one before

        // { show: true } puts what a step publishes on show here,
        // as if you had run that step yourself.
        let data = input.data;
        data = await run("Fetch orders", data, { show: true });
        data = await run("Clean \\"all\\" orders", data, { show: true });
        data = await run("reports/build", data, { show: true });
        return data;

        """)
        #expect(ScriptCompiler.syntaxProblem(in: source) == nil)
        #expect(ScriptHeader.parse(source)["name"] == "Weekly report")
        #expect(Reindenter.reindent(source) == source)
        #expect(ScriptFootprint(of: source).items == [.runs("Fetch orders"), .runs("Clean \\\"all\\\" orders"), .runs("reports/build")])

        let store = ScriptStore(directory: FileManager.default.temporaryDirectory.appending(path: "rhino-store-\(UUID().uuidString)"))
        let made = try store.create(named: "Weekly report", in: "flows", source: source)
        #expect(made.id == "flows/weekly-report")
        #expect(try store.source(of: made.id) == source)

        // What the sheet writes does what the sheet says.
        let (summary, recorder) = await run(ScriptStore.pipeline(name: "Flow", steps: ["fetch", "clean", "report"]))
        #expect(summary.error == nil)
        #expect(try json(summary.resultJSON) as? [String: Int] == ["count": 2])
        #expect(recorder.savedFiles.map(\.name) == ["Report"])
    }
}
