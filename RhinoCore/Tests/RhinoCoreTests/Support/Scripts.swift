@testable import RhinoCore

/// Serves script sources from a dictionary, keyed by script name.
struct Scripts: ScriptProvider {
    var sources: [String: String]

    func script(named name: String) -> ScriptSource? {
        sources[name].map { ScriptSource(id: name, source: $0) }
    }
}
