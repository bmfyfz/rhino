import Foundation

/// The scripts a new installation starts with. They are real files, in
/// `Resources/Examples`, so they can be read, run and changed like any
/// script: each shows a part of the API doing something useful with a public
/// service that needs no key.
enum Examples {
    /// Every example: its id (its path below the examples folder, without
    /// ".js") and its source, sorted by id.
    static let all: [(id: String, source: String)] = {
        guard let folder = Bundle.module.url(forResource: "Examples", withExtension: nil),
              let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else {
            preconditionFailure("RhinoCore is missing its bundled example scripts.")
        }
        let base = folder.resolvingSymlinksInPath().pathComponents.count
        var found: [(id: String, source: String)] = []
        for case let url as URL in walker where url.pathExtension == "js" {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let path = url.resolvingSymlinksInPath().pathComponents.dropFirst(base).joined(separator: "/")
            found.append(((path as NSString).deletingPathExtension, source))
        }
        return found.sorted { $0.id < $1.id }
    }()

    /// The examples shown to the AI writer as the style to follow: a few
    /// that between them use forms, tables and charts, memory, AI and
    /// pipelines. All of them would make every request longer for no gain.
    static let forWriter: [(id: String, source: String)] = {
        let chosen = ["weather-outlook", "hacker-news", "site-check", "AI/sort-feedback", "Pipelines/news-digest"]
        return chosen.compactMap { id in all.first { $0.id == id } }
    }()
}
