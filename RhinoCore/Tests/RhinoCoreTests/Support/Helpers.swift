import Foundation
import Testing
@testable import RhinoCore

/// A fresh session whose every request is answered by `StubProtocol`.
func stubbedSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return URLSession(configuration: configuration)
}

/// An engine over the given script sources, on the stubbed network, with a
/// runs folder of its own.
func makeEngine(_ sources: [String: String]) -> (engine: Engine, runs: URL) {
    let runs = FileManager.default.temporaryDirectory.appending(path: "rhino-tests-\(UUID().uuidString)")
    let engine = Engine(provider: Scripts(sources: sources), runsDirectory: runs, session: stubbedSession())
    return (engine, runs)
}

/// Parses JSON text, a bare value included; fails the test when there is no text.
func json(_ text: String?) throws -> Any {
    try JSONSerialization.jsonObject(with: Data(try #require(text).utf8), options: .fragmentsAllowed)
}
