import Foundation

/// A script on disk: one `.js` file with an optional comment header.
///
///     // @name Fetch users
///     // @description Pulls the user list
///     // @key cmd+shift+u
public struct Script: Identifiable, Hashable, Sendable {
    /// Where the file is below the scripts folder, without ".js":
    /// "fetch-users", or "reports/monthly" for one in a folder. This is what
    /// `run("id")` resolves first, and it changes when the script is moved.
    public let id: String
    /// The folder the script is in, relative to the scripts folder; empty at the top.
    public var folder: String {
        (id as NSString).deletingLastPathComponent
    }
    /// `@name`, or the id when the header has none.
    public var name: String
    public var summary: String?
    public var shortcut: Shortcut?
    /// `@schedule`, kept as written; see `Schedule` for what it may say.
    public var schedule: String?
    /// `@watch`, kept as written; see `FolderWatch` for what it may say.
    public var watch: String?
    public let url: URL
}

/// A keyboard shortcut written as `cmd+shift+u`.
public struct Shortcut: Hashable, Sendable {
    public enum Modifier: String, Hashable, Sendable, CaseIterable {
        case control, option, shift, command
    }

    /// A single lowercase character.
    public let key: Character
    public let modifiers: Set<Modifier>

    /// Needs exactly one key and at least one of command, control or option,
    /// so a shortcut can never swallow plain typing.
    public init?(_ text: String) {
        var modifiers: Set<Modifier> = []
        var key: Character?
        for token in text.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch token {
            case "cmd", "command", "⌘": modifiers.insert(.command)
            case "shift", "⇧": modifiers.insert(.shift)
            case "opt", "option", "alt", "⌥": modifiers.insert(.option)
            case "ctrl", "control", "⌃": modifiers.insert(.control)
            default:
                guard token.count == 1, key == nil, let character = token.first else { return nil }
                key = character
            }
        }
        guard let key, !modifiers.isDisjoint(with: [.command, .control, .option]) else { return nil }
        self.key = key
        self.modifiers = modifiers
    }

    /// For display, e.g. "⇧⌘U".
    public var symbols: String {
        let glyphs: [Modifier: String] = [.control: "⌃", .option: "⌥", .shift: "⇧", .command: "⌘"]
        return Modifier.allCases.filter(modifiers.contains).compactMap { glyphs[$0] }.joined() + String(key).uppercased()
    }
}

public enum ScriptHeader {
    /// Reads `// @key value` lines from the comment block at the top of a script.
    public static func parse(_ source: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard trimmed.hasPrefix("//") else { break }
            if let match = trimmed.firstMatch(of: /^\/\/\s*@([A-Za-z]+)\s+(.+)$/) {
                fields[String(match.1).lowercased()] = String(match.2).trimmingCharacters(in: .whitespaces)
            }
        }
        return fields
    }

    /// Whether a line is the header's `@name` or `@description`: text a
    /// search has already looked at as the script's name and description.
    static func isHeaderLine(_ line: String) -> Bool {
        line.firstMatch(of: /^\s*\/\/\s*@(name|description)\s/.ignoresCase()) != nil
    }
}
