import Foundation

/// A script as it was at some moment, and why that moment was kept.
public struct ScriptVersion: Identifiable, Codable, Hashable, Sendable {
    public enum Reason: Codable, Hashable, Sendable {
        /// How the script was when versions were first kept for it.
        case original
        /// Saved after editing by hand.
        case edit
        /// Written or changed by the AI; the text is what was asked for.
        case ai(String)
        /// Changed by the AI to repair a failed run.
        case repair
        /// An AI change was undone.
        case undo
        /// An earlier version, from that date, was put back.
        case restore(Date)
        /// Replaced from outside the app, with the `rhino` command line tool.
        case commandLine
    }

    public let id: UUID
    public let date: Date
    public let reason: Reason
    public let source: String

    public init(id: UUID = UUID(), date: Date, reason: Reason, source: String) {
        self.id = id
        self.date = date
        self.reason = reason
        self.source = source
    }
}

/// Every script's earlier versions, as one small file per version in a
/// folder per script, so they can be looked at and backed up like the
/// scripts themselves.
public struct ScriptVersions: Sendable {
    public let directory: URL
    /// How many versions of each script are kept; older ones are forgotten.
    public let limit: Int
    /// Saves by hand this close together count as one burst of editing and
    /// leave one version, not one per save.
    public let editWindow: TimeInterval

    public init(directory: URL, limit: Int = 100, editWindow: TimeInterval = 10 * 60) {
        self.directory = directory
        self.limit = limit
        self.editWindow = editWindow
    }

    /// A script's versions, newest first.
    public func versions(of script: String) -> [ScriptVersion] {
        files(of: script).reversed().compactMap { url in
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(ScriptVersion.self, from: $0) }
        }
    }

    /// Keeps `source` as the script's newest version. `previous` is how the
    /// script was before this change; it becomes the first version when
    /// nothing was kept yet, so there is always something to go back to.
    /// Returns nil when the newest version already is this source.
    @discardableResult
    public func record(_ source: String, of script: String, reason: ScriptVersion.Reason, previous: String? = nil, now: Date = Date()) throws -> ScriptVersion? {
        var existing = files(of: script)
        var latest = existing.last.flatMap { url in
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(ScriptVersion.self, from: $0) }
        }

        if latest == nil, let previous, previous != source, !previous.allSatisfy(\.isWhitespace) {
            let first = ScriptVersion(date: now.addingTimeInterval(-0.001), reason: .original, source: previous)
            existing.append(try write(first, of: script))
            latest = first
        }
        guard latest?.source != source else { return nil }

        // One burst of editing by hand is one version: the newer save replaces the older.
        if reason == .edit, let latest, latest.reason == .edit, now.timeIntervalSince(latest.date) < editWindow, let file = existing.last {
            try? FileManager.default.removeItem(at: file)
            existing.removeLast()
        }

        let version = ScriptVersion(date: now, reason: reason, source: source)
        existing.append(try write(version, of: script))
        for old in existing.dropLast(limit) {
            try? FileManager.default.removeItem(at: old)
        }
        return version
    }

    /// Carries a script's versions over to its new id after it was moved.
    public func rename(_ script: String, to renamed: String) {
        let old = folder(of: script)
        guard FileManager.default.fileExists(atPath: old.path(percentEncoded: false)) else { return }
        try? FileManager.default.removeItem(at: folder(of: renamed))
        try? FileManager.default.moveItem(at: old, to: folder(of: renamed))
    }

    /// Forgets every version of a script.
    public func removeAll(of script: String) {
        try? FileManager.default.removeItem(at: folder(of: script))
    }

    // MARK: - Private

    private func folder(of script: String) -> URL {
        let name = script.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-_"))) ?? "script"
        return directory.appending(path: name, directoryHint: .isDirectory)
    }

    /// The version files, oldest first: their names start with the time.
    private func files(of script: String) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder(of: script), includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func write(_ version: ScriptVersion, of script: String) throws -> URL {
        let folder = folder(of: script)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Milliseconds since 1970, padded, so names sort in the order of time.
        let stamp = String(format: "%015.0f", (version.date.timeIntervalSince1970 * 1000).rounded())
        let url = folder.appending(path: "\(stamp)-\(version.id.uuidString.prefix(8)).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(version).write(to: url, options: .atomic)
        return url
    }
}
