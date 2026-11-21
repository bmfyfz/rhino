import Foundation
import Testing
@testable import RhinoCore

/// `pipeline()`: scripts run one after another, each fed by the one before.
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

    @Test func eachStepGetsTheResultOfTheOneBefore() async throws {
        let (summary, recorder) = await run(#"return await pipeline("fetch", "clean", "report");"#, data: #"{"since":"Monday"}"#)

        #expect(summary.error == nil)
        // The last step's result is the pipeline's.
        #expect(try json(summary.resultJSON) as? [String: Int] == ["count": 2])
        #expect(recorder.runs.map(\.script) == ["flow", "fetch", "clean", "report"])
        #expect(recorder.logs == ["Step 1 of 3: fetch", "Step 2 of 3: clean", "Kept 2 paid orders", "Step 3 of 3: report"])

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

    @Test func aFunctionCanBeAStep() async throws {
        let (summary, recorder) = await run("""
        return await pipeline(
          "fetch",
          function onlyUnpaid(data) { return data.orders.filter((order) => !order.paid); },
          async (orders) => { await sleep(1); return orders.map((order) => order.id); },
        );
        """)
        #expect(summary.error == nil)
        #expect(try json(summary.resultJSON) as? [Int] == [2])
        #expect(recorder.logs == ["Step 1 of 3: fetch", "Step 2 of 3: onlyUnpaid", "Step 3 of 3: a function"])

        // A list works as well as separate arguments, and a step that returns nothing hands on null.
        let listed = await run(#"return await pipeline(["fetch", () => {}, (data) => data === null]);"#)
        #expect(try json(listed.summary.resultJSON) as? Bool == true)
    }

    @Test func aFailedStepStopsThePipelineAndSaysWhichOne() async throws {
        let (summary, recorder) = await run(#"output.log("starting");\#nreturn await pipeline("fetch", "broken", "report");"#)

        #expect(summary.error?.message == "Step 2 of 3, “broken”, failed: no data today")
        // The place is where it really went wrong: in the step, not in the pipeline.
        #expect(summary.error?.script == "broken")
        #expect(summary.error?.line == 2)
        #expect(recorder.runs.map(\.script) == ["flow", "fetch", "broken"])
        #expect(recorder.logs == ["starting", "Step 1 of 3: fetch", "Step 2 of 3: broken", "about to fail"])

        let glue = await run("return await pipeline('fetch',\n  () => { throw new Error('bad glue'); });")
        #expect(glue.summary.error?.message == "Step 2 of 2, “a function”, failed: bad glue")
        #expect(glue.summary.error?.script == "flow")
        let unknown = await run(#"return await pipeline("fetch", "nowhere");"#)
        #expect(unknown.summary.error?.message.hasPrefix("Step 2 of 2, “nowhere”, failed:") == true)
    }

    @Test func refusesNonsense() async throws {
        #expect(await run("await pipeline();").summary.error?.message.contains("needs at least one step") == true)
        #expect(await run("await pipeline('fetch', 42);").summary.error?.message == "pipeline(): step 2 is neither a script's name nor a function.")
    }

    @Test func aPlainRunStillKeepsItsOutputsToItself() async throws {
        let (summary, recorder) = await run(#"const data = await run("fetch"); output.json(data.orders.length);"#)
        #expect(summary.error == nil)
        // Only what the calling script published is shown; `run()` is a function call.
        #expect(recorder.outputs.count == 1)
        #expect(try json(recorder.outputs[0].json) as? Int == 3)
    }

    @Test func writesAPipelineScript() throws {
        let source = ScriptStore.pipeline(name: "Weekly report", steps: ["Fetch orders", "Clean \"all\" orders", "reports/build"])
        #expect(source == """
        // @name Weekly report
        // @description Runs Fetch orders, Clean "all" orders, then reports/build; each step gets the result of the one before

        return await pipeline(
          "Fetch orders",
          "Clean \\"all\\" orders",
          "reports/build",
        );

        """)
        #expect(ScriptCompiler.syntaxProblem(in: source) == nil)
        #expect(ScriptHeader.parse(source)["name"] == "Weekly report")
        #expect(Reindenter.reindent(source) == source)

        let store = ScriptStore(directory: FileManager.default.temporaryDirectory.appending(path: "rhino-store-\(UUID().uuidString)"))
        let made = try store.create(named: "Weekly report", in: "flows", source: source)
        #expect(made.id == "flows/weekly-report")
        #expect(try store.source(of: made.id) == source)
    }
}
