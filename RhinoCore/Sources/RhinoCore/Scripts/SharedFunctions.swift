import Foundation
import JavaScriptCore

/// One file of the user's own functions, available in every script.
public struct SharedFile: Identifiable, Hashable, Sendable {
    /// The file's name without ".js".
    public let id: String
    public var source: String

    public init(id: String, source: String) {
        self.id = id
        self.source = source
    }
}

/// Where the engine gets the shared functions from.
public protocol SharedFunctionProvider: Sendable {
    /// The files, in the order they are loaded: a file can use what the
    /// files before it define.
    func sharedFiles() -> [SharedFile]
}

/// The user's shared functions: plain `.js` files in a folder. What a file
/// declares at its top level (`function name() {}`, `const name = …`,
/// `class Name {}`) can be used in every script, like the built-in API.
public struct SharedLibrary: SharedFunctionProvider {
    public struct Problem: Error, Equatable, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// A function a file defines, for telling people and the AI writer what there is.
    public struct Signature: Hashable, Sendable {
        public let name: String
        /// As written between the parentheses: "date, style = \"short\"".
        public let parameters: String
        /// The comment directly above it, without the comment marks.
        public let comment: String
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    // MARK: - Files

    public func sharedFiles() -> [SharedFile] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == "js" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.deletingPathExtension().lastPathComponent.localizedStandardCompare($1.deletingPathExtension().lastPathComponent) == .orderedAscending }
            .compactMap { url in
                (try? String(contentsOf: url, encoding: .utf8)).map { SharedFile(id: url.deletingPathExtension().lastPathComponent, source: $0) }
            }
    }

    public func save(_ source: String, to name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(source.utf8).write(to: url(for: name), options: .atomic)
    }

    /// Creates a file with a starter function in it and returns it.
    public func create(named name: String) throws -> SharedFile {
        let base = ScriptStore.slug(name)
        var id = base
        var suffix = 2
        while FileManager.default.fileExists(atPath: url(for: id).path(percentEncoded: false)) {
            id = "\(base)-\(suffix)"
            suffix += 1
        }
        let source = Self.template(function: Self.functionName(from: id))
        try save(source, to: id)
        return SharedFile(id: id, source: source)
    }

    /// Moves a file to the Trash.
    public func delete(_ name: String) throws {
        try FileManager.default.trashItem(at: url(for: name), resultingItemURL: nil)
    }

    private func url(for name: String) -> URL {
        directory.appending(path: "\(name).js")
    }

    // MARK: - What a file defines

    /// The names a file makes available: what it declares at the start of a
    /// line with `function`, `const`, `let`, `var` or `class`.
    public static func names(definedIn source: String) -> [String] {
        var names: [String] = []
        for match in source.matches(of: /(?m)^(?:async\s+)?function\s*\*?\s*([A-Za-z_$][\w$]*)|^(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=|^class\s+([A-Za-z_$][\w$]*)/) {
            if let name = match.1 ?? match.2 ?? match.3, !names.contains(String(name)) {
                names.append(String(name))
            }
        }
        return names
    }

    /// The functions a file defines, with their parameters and the comment above each.
    public static func signatures(in source: String) -> [Signature] {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var found: [Signature] = []
        for (index, line) in lines.enumerated() {
            guard let match = line.firstMatch(of: /^(?:async\s+)?function\s*\*?\s*([A-Za-z_$][\w$]*)\s*\(([^)]*)\)/)
                ?? line.firstMatch(of: /^(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?\(([^)]*)\)\s*=>/) else { continue }
            // The comment lines directly above, nearest last.
            var comment: [String] = []
            var above = index - 1
            while above >= 0 {
                let text = lines[above].trimmingCharacters(in: .whitespaces)
                guard text.hasPrefix("//") || text.hasPrefix("*") || text.hasPrefix("/*") else { break }
                let words = text.replacing(/^(\/\/+|\/\*+|\*+\/?)\s?/, with: "").replacing(/\s*\*+\/$/, with: "")
                if !words.isEmpty { comment.insert(words, at: 0) }
                above -= 1
            }
            found.append(Signature(
                name: String(match.1),
                parameters: String(match.2).trimmingCharacters(in: .whitespaces),
                comment: comment.joined(separator: " ")
            ))
        }
        return found
    }

    /// What stops a file from being used, in words for its author: a mistake
    /// in the JavaScript, a name the built-in API already has, or one
    /// another file already defines. Nil when it is fine.
    public static func problem(in file: SharedFile, among others: [SharedFile] = []) -> String? {
        let names = names(definedIn: file.source)
        if let taken = names.first(where: ScriptCompiler.globals.contains) {
            return "“\(taken)” is the name of something built in. Call yours something else."
        }
        for other in others where other.id != file.id {
            if let twice = names.first(where: Self.names(definedIn: other.source).contains) {
                return "“\(twice)” is already defined in \(other.id). A name can only be defined once."
            }
        }
        if let mistake = ScriptCompiler.firstSyntaxError(in: wrap(file.source, names: names, visible: ScriptCompiler.globals)) {
            return mistake
        }
        return nil
    }

    /// A file as a program: a function that, given the API and the shared
    /// functions loaded so far, returns what the file defines. It starts on
    /// the file's first line, so line numbers in errors match the file.
    static func wrap(_ source: String, names: [String], visible: [String]) -> String {
        "(function (__api) { \"use strict\"; const { \(visible.joined(separator: ", ")) } = __api; "
            + source
            + "\n; return { \(names.joined(separator: ", ")) }; })"
    }

    /// What a shared file is called in an error's location.
    static func location(of file: SharedFile) -> String {
        "Shared functions/\(file.id)"
    }

    static func template(function name: String) -> String {
        """
        // Functions and const values declared at the start of a
        // line can be used in every script. They can call the
        // built-in API (get, output, secrets, …) as a script does.

        // Say here what the function does; the AI writer reads it.
        function \(name)(value) {
          return value;
        }

        """
    }

    /// "date-helpers" becomes "dateHelpers".
    static func functionName(from id: String) -> String {
        let words = id.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let name = words.enumerated().map { $0.offset == 0 ? $0.element.lowercased() : $0.element.prefix(1).uppercased() + $0.element.dropFirst() }.joined()
        guard let first = name.first, first.isLetter else { return "helper" }
        return name
    }
}
