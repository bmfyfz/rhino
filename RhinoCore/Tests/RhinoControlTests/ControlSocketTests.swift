import Foundation
import Synchronization
import Testing
@testable import RhinoControl

/// The tool and the app talking over a socket: requests, answers that
/// arrive in pieces, and noticing when the other end has gone.
@Suite struct ControlSocketTests {
    /// A short path of its own: socket paths cannot be long.
    static func socketPath() -> String {
        "/tmp/rhino-test-\(UUID().uuidString.prefix(8)).sock"
    }

    /// The tool's end waits for its answer the plain way, by blocking. A
    /// test must not do that on the threads Swift runs tests and tasks on:
    /// on a machine with few cores every one of them would be waiting for
    /// an answer that needs one of them to be given. So the tool's part of
    /// each test runs on a thread of its own, as the real tool does.
    static func asTheTool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    @Test func aRequestIsAnsweredWithItsResult() async throws {
        let path = Self.socketPath()
        let listener = try ControlListener(path: path) { request, connection in
            guard case .show(let script) = request else { return connection.send(.failed("unexpected")) }
            connection.send(.done(.script(ScriptInfo(id: script, name: "Site check"), source: "output.log('hi');\n")))
        }
        defer { listener.stop() }

        let result = try await Self.asTheTool { try ControlClient(path: path).perform(.show(script: "site-check")) }
        #expect(result == .script(ScriptInfo(id: "site-check", name: "Site check"), source: "output.log('hi');\n"))
        // Only the user can open the socket.
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func messagesArriveInOrderBeforeTheResult() async throws {
        let path = Self.socketPath()
        let started = Date(timeIntervalSince1970: 1_800_000_000.123)
        let listener = try ControlListener(path: path) { _, connection in
            connection.send(.waiting("Waiting for you to approve it in Rhino"))
            for number in 1...3 {
                connection.send(.line(RunLine(time: started, script: "s", kind: .log, text: "line \(number)", level: "info")))
            }
            let run = RunBrief(id: "r1", script: "s", startedAt: started, duration: 0.5, status: .finished, trigger: "commandLine")
            connection.send(.done(.run(RunReport(run: run, result: .object(["count": .integer(3), "ok": .bool(true)])))))
        }
        defer { listener.stop() }

        let (result, received) = try await Self.asTheTool {
            var received: [ControlMessage] = []
            let result = try ControlClient(path: path).perform(.run(script: "s", data: #"{"a":1}"#, files: ["/tmp/in.csv"])) { received.append($0) }
            return (result, received)
        }
        #expect(received.count == 4)
        #expect(received.first == .waiting("Waiting for you to approve it in Rhino"))
        #expect(received.last == .line(RunLine(time: started, script: "s", kind: .log, text: "line 3", level: "info")))
        guard case .run(let report) = result else { Issue.record("not a run"); return }
        #expect(report.run.startedAt == started)
        #expect(report.result == .object(["count": .integer(3), "ok": .bool(true)]))
    }

    @Test func aRefusalIsAnErrorWithTheAppsWords() async throws {
        let path = Self.socketPath()
        let listener = try ControlListener(path: path) { _, connection in
            connection.send(.failed("No script is called “nope”."))
        }
        defer { listener.stop() }

        await #expect(throws: ControlClient.Refusal(message: "No script is called “nope”.")) {
            try await Self.asTheTool { try ControlClient(path: path).perform(.show(script: "nope")) }
        }
    }

    @Test func nobodyListeningIsToldApart() async throws {
        let path = Self.socketPath()
        #expect(!ControlClient(path: path).isAnswered)
        await #expect(throws: ControlClient.Unreachable.self) {
            try await Self.asTheTool { try ControlClient(path: path).perform(.status) }
        }

        // After the app stops listening the socket is gone again.
        let listener = try ControlListener(path: path) { _, connection in connection.send(.done(.ok(""))) }
        #expect(ControlClient(path: path).isAnswered)
        listener.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(!ControlClient(path: path).isAnswered)
    }

    @Test func aSecondAppDoesNotTakeTheSocket() async throws {
        let path = Self.socketPath()
        let first = try ControlListener(path: path) { _, connection in connection.send(.done(.ok("first"))) }
        defer { first.stop() }
        #expect(throws: ControlError.self) {
            _ = try ControlListener(path: path) { _, connection in connection.send(.done(.ok("second"))) }
        }
        #expect(try await Self.asTheTool { try ControlClient(path: path).perform(.status) } == .ok("first"))
    }

    @Test func theAppLearnsWhenTheToolGoesAway() async throws {
        let path = Self.socketPath()
        let (noticed, continuation) = AsyncStream.makeStream(of: Void.self)
        let listener = try ControlListener(path: path) { _, connection in
            connection.whenClosed { continuation.yield() }
            // A run that goes on and on: only the tool leaving is noticed.
            try? await Task.sleep(for: .seconds(30))
        }
        defer { listener.stop() }

        // The tool asks, then is interrupted before any answer comes.
        let descriptor = try Plumbing.socket()
        #expect(try Plumbing.withAddress(path) { Darwin.connect(descriptor, $0, $1) } == 0)
        #expect(Plumbing.write(try Wire.line(ControlEnvelope(.run(script: "s", data: nil, files: []))), to: descriptor))
        try await Task.sleep(for: .milliseconds(100))
        close(descriptor)

        var iterator = noticed.makeAsyncIterator()
        await iterator.next()
    }

    @Test func anotherVersionOfTheProtocolIsTurnedAway() async throws {
        let path = Self.socketPath()
        let listener = try ControlListener(path: path) { _, connection in connection.send(.done(.ok(""))) }
        defer { listener.stop() }

        let answer = try await Self.asTheTool { () -> Data? in
            let descriptor = try Plumbing.socket()
            defer { close(descriptor) }
            guard try Plumbing.withAddress(path, { Darwin.connect(descriptor, $0, $1) }) == 0,
                  Plumbing.write(try Wire.line(ControlEnvelope(.status, version: 99)), to: descriptor) else { return nil }
            var reader = LineReader(descriptor: descriptor)
            return reader.next()
        }
        let line = try #require(answer)
        guard case .failed(let message) = try Wire.decode(ControlMessage.self, from: line) else { Issue.record("not refused"); return }
        #expect(message.contains("different versions"))
    }

    @Test func jsonValuesKeepTheirShape() throws {
        let value = try #require(JSONValue(json: #"{"n":1,"f":1.5,"big":9007199254740993,"s":"x","list":[true,null],"o":{}}"#))
        #expect(value == .object([
            "n": .integer(1), "f": .number(1.5), "big": .integer(9_007_199_254_740_993), "s": .string("x"),
            "list": .array([.bool(true), .null]), "o": .object([:]),
        ]))
        #expect(JSONValue(json: "not json") == nil)
        // Every request survives the trip.
        let requests: [ControlRequest] = [
            .status, .list, .create(name: "A", folder: "x/y", source: nil), .write(script: "a", source: "1;\n2;"),
            .check(source: "x", script: nil), .runs(script: nil, limit: 5), .log(run: "id", script: nil), .schedules(paused: true),
        ]
        for request in requests {
            let line = try Wire.line(ControlEnvelope(request))
            #expect(line.filter { $0 == 0x0A }.count == 1)
            #expect(try Wire.decode(ControlEnvelope.self, from: line.dropLast()).request == request)
        }
    }
}
