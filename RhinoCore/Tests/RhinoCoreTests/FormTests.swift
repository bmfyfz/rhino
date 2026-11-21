import Foundation
import Testing
@testable import RhinoCore

/// `input.form()`: describing fields, typed values, defaults on unattended runs, and validation.
@Suite struct FormTests {
    static let script = """
    const values = await input.form(
      {
        name: { default: "report", required: true },
        count: { type: "number", default: 3, min: 1 },
        dryRun: { default: true },
        env: { label: "Environment", options: [{ label: "Staging", value: "stg" }, { label: "Production", value: "prod" }], default: "prod" },
        pageSize: { options: [10, 20] },
        day: { type: "date", default: "2026-03-05" },
        at: { type: "datetime", default: "2026-03-05T10:30:00Z" },
        alarm: { type: "time", default: "09:05" },
        notes: { type: "textarea", help: "Anything else" },
        source: { type: "file", ext: ".CSV" },
      },
      { title: "Settings", description: "Pick wisely", submit: "Go" }
    );
    output.json({
      ...values,
      at: new Date(values.at).getTime(),
      source: values.source ? { name: values.source.name, text: await values.source.text() } : null,
    });
    """

    @Test func describesFieldsAndReturnsTypedValues() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "rhino-\(UUID().uuidString).csv")
        try Data("a,b".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let (engine, _) = makeEngine(["m": Self.script])
        let recorder = Recorder { request in
            // Start from what the form shows, then change a few fields like a person would.
            var values = Dictionary(uniqueKeysWithValues: request.fields.map { ($0.id, $0.defaultValue) })
            values["name"] = .text("custom")
            values["pageSize"] = .option(1)
            values["notes"] = .text("hi")
            values["source"] = .file(file)
            return .form(values)
        }
        let summary = await engine.run("m", interactive: true, events: recorder.record)
        #expect(summary.error == nil)

        let prompt = try #require(recorder.events.compactMap { if case .prompt(let request) = $0 { request } else { nil } }.first)
        #expect(prompt.kind == .form)
        #expect(prompt.message == "Settings")
        #expect(prompt.detail == "Pick wisely")
        #expect(prompt.submitLabel == "Go")
        #expect(prompt.fields.map(\.id) == ["name", "count", "dryRun", "env", "pageSize", "day", "at", "alarm", "notes", "source"])
        #expect(prompt.fields.map(\.kind) == [.text, .number, .toggle, .select, .select, .date, .dateTime, .time, .multiline, .file])
        #expect(prompt.fields.map(\.label) == ["Name", "Count", "Dry run", "Environment", "Page size", "Day", "At", "Alarm", "Notes", "Source"])

        let fields = Dictionary(uniqueKeysWithValues: prompt.fields.map { ($0.id, $0) })
        #expect(fields["name"]?.isRequired == true)
        #expect(fields["count"]?.minimum == 1)
        #expect(fields["env"]?.options == ["Staging", "Production"])
        #expect(fields["env"]?.defaultValue == .option(1))
        #expect(fields["pageSize"]?.defaultValue == FormValue.none)
        #expect(fields["notes"]?.help == "Anything else")
        #expect(fields["source"]?.options == ["csv"])

        let result = try #require(try json(summary.resultJSON) as? [String: Any])
        #expect(result["name"] as? String == "custom")
        #expect(result["count"] as? Int == 3)
        #expect(result["dryRun"] as? Bool == true)
        // A choice comes back as the option's own value, not its label or index.
        #expect(result["env"] as? String == "prod")
        #expect(result["pageSize"] as? Int == 20)
        #expect(result["day"] as? String == "2026-03-05")
        #expect(result["alarm"] as? String == "09:05")
        #expect(result["notes"] as? String == "hi")
        let expected = try #require(ISO8601DateFormatter().date(from: "2026-03-05T10:30:00Z")).timeIntervalSince1970 * 1000
        #expect(result["at"] as? Double == expected)
        #expect(result["source"] as? [String: String] == ["name": file.lastPathComponent, "text": "a,b"])
    }

    @Test func unattendedRunsUseDefaults() async throws {
        let (engine, _) = makeEngine([
            "defaults": """
            const values = await input.form({
              name: { default: "report", required: true },
              limit: { type: "number" },
              env: { options: ["staging", "prod"], required: true },
              region: { options: ["eu", "us"] },
              dryRun: { type: "toggle" },
            });
            output.json(values);
            """,
            "needsAnswer": #"await input.form({ apiKey: { label: "API key", type: "secret", required: true } });"#,
        ])
        let result = try #require(try json(await engine.run("defaults").resultJSON) as? [String: Any])
        #expect(result["name"] as? String == "report")
        #expect(result["limit"] is NSNull)
        #expect(result["env"] as? String == "staging")
        #expect(result["region"] is NSNull)
        #expect(result["dryRun"] as? Bool == false)

        let message = try #require(await engine.run("needsAnswer").error?.message)
        #expect(message.contains("API key"))
        #expect(message.contains("unattended"))
    }

    @Test func rejectsBadForms() async throws {
        let (engine, _) = makeEngine([
            "unknown": "output.log('before');\nawait input.form({ when: { type: 'calendar' } });",
            "empty": "await input.form({});",
            "cancelled": "await input.form({ name: 'Your name' });",
        ])
        let unknown = try #require(await engine.run("unknown").error)
        #expect(unknown.message.contains(#"field "when" has unknown type "calendar""#))
        #expect(unknown.line == 2)
        #expect(await engine.run("empty").error?.message.contains("at least one field") == true)
        #expect(await engine.run("cancelled", interactive: true, events: Recorder().record).error?.message.contains("Cancelled") == true)
    }

    @Test func checksValues() throws {
        let field = try #require(FormField(json: ["key": "n", "type": "number", "required": true, "min": 1, "max": 5]))
        #expect(!field.accepts(.none))
        #expect(!field.accepts(.number(0)))
        #expect(field.accepts(.number(5)))

        let text = try #require(FormField(json: ["key": "t", "type": "text", "required": true]))
        #expect(!text.accepts(.text("   ")))
        #expect(text.accepts(.text("x")))

        let choice = try #require(FormField(json: ["key": "c", "type": "select", "options": ["a", "b"]]))
        #expect(choice.accepts(.none))
        #expect(!choice.accepts(.option(2)))
    }
}
