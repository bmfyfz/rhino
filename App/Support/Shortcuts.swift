import AppIntents
import RhinoCore
import Foundation

// Rhino in the Shortcuts app: a "Run Script" action, so a script can be a step
// in a shortcut, run from Spotlight, a keyboard shortcut or an automation.

/// A script, as Shortcuts lists and remembers it.
nonisolated struct ScriptEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Script"
    static let defaultQuery = ScriptQuery()

    let id: String
    let name: String
    let summary: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: summary.map { "\($0)" })
    }
}

nonisolated struct ScriptQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ScriptEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ScriptEntity] {
        await MainActor.run {
            AppModel.shared.refreshFromDisk()
            return AppModel.shared.scripts.map { ScriptEntity(id: $0.id, name: $0.name, summary: $0.summary) }
        }
    }
}

struct RunScriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Script"
    static let description = IntentDescription(
        "Runs a Rhino script and gives back what it produced. Nobody is asked anything while it runs, so the script needs defaults for its questions.",
        categoryName: "Scripts"
    )

    @Parameter(title: "Script")
    var script: ScriptEntity

    @Parameter(title: "Input", description: "Text or JSON the script finds in input.data.")
    var input: String?

    @Parameter(title: "Files", description: "Files the script gets from input.file().")
    var files: [IntentFile]?

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$script)") {
            \.$input
            \.$files
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        // Files that are not on disk yet are written out, since a script reads files by path.
        var urls: [URL] = []
        for file in files ?? [] {
            if let url = file.fileURL {
                urls.append(url)
            } else {
                let folder = FileManager.default.temporaryDirectory.appending(path: "rhino-shortcut-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appending(path: file.filename)
                try file.data.write(to: url)
                urls.append(url)
            }
        }
        let result = try await AppModel.shared.runForShortcut(script.id, data: input, files: urls)
        return .result(value: result)
    }
}

nonisolated struct RhinoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunScriptIntent(),
            phrases: ["Run a script in \(.applicationName)", "Run a \(.applicationName) script"],
            shortTitle: "Run Script",
            systemImageName: "gearshape.2"
        )
    }
}
