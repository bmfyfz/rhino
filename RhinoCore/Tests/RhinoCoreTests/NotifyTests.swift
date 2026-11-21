import Foundation
import Testing
@testable import RhinoCore

/// `notify()`: titles and messages, hidden secrets, the per-run limit, and chained scripts.
@Suite struct NotifyTests {
    @Test func sendsATitleAndAnOptionalMessage() async throws {
        let (engine, _) = makeEngine(["m": """
        notify("Backup finished", "12 files copied");
        notify("  Just a title  ");
        notify("Counts", { copied: 12 });
        output.log("after");
        """])
        let recorder = Recorder()
        let summary = await engine.run("m", events: recorder.record)

        #expect(summary.error == nil)
        #expect(recorder.notifications.map(\.title) == ["Backup finished", "Just a title", "Counts"])
        #expect(recorder.notifications[0].message == "12 files copied")
        #expect(recorder.notifications[1].message == "")
        #expect(recorder.notifications[2].message.contains("\"copied\": 12"))
        // It does not wait for anything, so the script carries on.
        #expect(recorder.logs == ["after"])
    }

    @Test func needsATitle() async throws {
        let (engine, _) = makeEngine(["m": "output.log('before');\nnotify('   ');"])
        let recorder = Recorder()
        let summary = await engine.run("m", events: recorder.record)

        #expect(summary.error?.message.contains("notify() needs a title") == true)
        #expect(summary.error?.line == 2)
        #expect(recorder.notifications.isEmpty)
    }

    @Test func keepsSecretsOutOfNotifications() async throws {
        let engine = Engine(
            provider: Scripts(sources: ["m": """
            const token = await secrets.get("API_TOKEN", "A token");
            notify(`Signed in with ${token}`, `Token: ${token}`);
            """]),
            runsDirectory: FileManager.default.temporaryDirectory.appending(path: "rhino-tests-\(UUID().uuidString)"),
            session: stubbedSession(),
            secrets: InMemorySecretStore(["API_TOKEN": "s3cr3t-value"])
        )
        let recorder = Recorder()
        let summary = await engine.run("m", events: recorder.record)

        #expect(summary.error == nil)
        let notification = try #require(recorder.notifications.first)
        #expect(!notification.title.contains("s3cr3t-value"))
        #expect(!notification.message.contains("s3cr3t-value"))
        #expect(notification.title.hasPrefix("Signed in with "))
    }

    @Test func showsOnlySoManyPerRun() async throws {
        let (engine, _) = makeEngine(["m": """
        for (let i = 1; i <= 25; i++) notify(`Row ${i}`);
        output.json("done");
        """])
        let recorder = Recorder()
        let summary = await engine.run("m", events: recorder.record)

        #expect(summary.error == nil)
        #expect(recorder.notifications.count == Engine.maxNotifications)
        #expect(recorder.notifications.last?.title == "Row \(Engine.maxNotifications)")
        // Said once, not fifteen times.
        #expect(recorder.logs.filter { $0.contains("notify() was called more than") }.count == 1)
    }

    @Test func aChainedScriptNotifiesAsItself() async throws {
        let (engine, _) = makeEngine([
            "parent": #"await run("child"); notify("Parent done");"#,
            "child": #"notify("Child done");"#,
        ])
        let recorder = Recorder()
        let summary = await engine.run("parent", events: recorder.record)

        #expect(summary.error == nil)
        let scripts = recorder.notifications.map { notification in
            recorder.runs.first { $0.id == notification.runID }?.script
        }
        #expect(recorder.notifications.map(\.title) == ["Child done", "Parent done"])
        #expect(scripts == ["child", "parent"])
    }
}
