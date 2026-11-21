import Foundation

/// Finding scripts by what they are called, what they say they do, and what
/// is in their code.
public enum ScriptSearch {
    public struct Match: Identifiable, Hashable, Sendable {
        public enum Place: Hashable, Sendable {
            case name
            case description
            /// A line of the code, counted from 1.
            case code(line: Int)
        }

        public let scriptID: String
        public let place: Place
        /// The text that matched: the name, the description, or the line of code, trimmed.
        public let text: String

        public var id: String { "\(scriptID)#\(place)" }
    }

    /// The most lines of one script's code shown for a search.
    public static let linesPerScript = 3

    /// What matches `query` in the scripts, best first: names, then
    /// descriptions, then code. Upper and lower case and accents make no
    /// difference. A script found by name is not listed again for its
    /// description, but its matching lines of code are, since those say where.
    public static func matches(for query: String, in scripts: [(script: Script, source: String)]) -> [Match] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        func found(in text: String) -> Bool {
            text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }

        var names: [Match] = []
        var descriptions: [Match] = []
        var code: [Match] = []
        for (script, source) in scripts {
            if found(in: script.name) || found(in: (script.id as NSString).lastPathComponent) {
                names.append(Match(scriptID: script.id, place: .name, text: script.name))
            } else if let summary = script.summary, found(in: summary) {
                descriptions.append(Match(scriptID: script.id, place: .description, text: summary))
            }

            var shown = 0
            for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where shown < linesPerScript {
                let line = String(line)
                // The header was searched as name and description already.
                guard !ScriptHeader.isHeaderLine(line), found(in: line) else { continue }
                code.append(Match(scriptID: script.id, place: .code(line: index + 1), text: line.trimmingCharacters(in: .whitespaces)))
                shown += 1
            }
        }
        return names + descriptions + code
    }
}
