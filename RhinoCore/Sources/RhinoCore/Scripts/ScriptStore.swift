import Foundation

/// Scripts live as plain files in one folder, with folders of their own
/// inside it if the user wants, so they can be edited with any editor, kept
/// in git, or written by an AI.
public struct ScriptStore: ScriptProvider {
    public struct Problem: Error, Equatable, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    // MARK: - Reading

    /// Every script, in every folder, sorted by name.
    public func scripts() -> [Script] {
        contents().files
            .compactMap(script(at:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Every folder below the scripts folder, as its path relative to it
    /// ("reports", "reports/2026"), sorted. Empty folders count.
    public func folders() -> [String] {
        contents().folders.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public func source(of id: String) throws -> String {
        try String(contentsOf: url(for: id), encoding: .utf8)
    }

    public func script(named name: String) -> ScriptSource? {
        let all = scripts()
        let wanted = name.hasSuffix(".js") ? String(name.dropLast(3)) : name
        func fileName(_ script: Script) -> String { (script.id as NSString).lastPathComponent }
        // The path first, then the title, then the file name alone if only one script has it.
        let sameFileName = all.filter { fileName($0).caseInsensitiveCompare(wanted) == .orderedSame }
        let match = all.first { $0.id == wanted }
            ?? all.first { $0.id.caseInsensitiveCompare(wanted) == .orderedSame }
            ?? all.first { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
            ?? (sameFileName.count == 1 ? sameFileName.first : nil)
        guard let match, let source = try? source(of: match.id) else { return nil }
        return ScriptSource(id: match.id, source: source)
    }

    // MARK: - Changing scripts

    public func save(_ source: String, to id: String) throws {
        let url = url(for: id)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(source.utf8).write(to: url, options: .atomic)
    }

    /// Creates a script from the starter template, in a folder or at the top,
    /// and returns it.
    public func create(named name: String, in folder: String = "", source: String? = nil) throws -> Script {
        let id = unusedID(Self.slug(name), in: try Self.folderPath(folder))
        try save(source ?? Self.template(name: name), to: id)
        guard let script = script(at: url(for: id)) else { throw CocoaError(.fileReadUnknown) }
        return script
    }

    /// Moves a script into a folder ("" is the top) and returns its new id.
    /// If a script of that file name is already there, this one gets a number.
    @discardableResult
    public func move(_ id: String, to folder: String) throws -> String {
        let folder = try Self.folderPath(folder)
        guard (id as NSString).deletingLastPathComponent != folder else { return id }
        let moved = unusedID((id as NSString).lastPathComponent, in: folder)
        let destination = url(for: moved)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url(for: id), to: destination)
        return moved
    }

    /// Moves the script's file to the Trash.
    public func delete(_ id: String) throws {
        try FileManager.default.trashItem(at: url(for: id), resultingItemURL: nil)
    }

    // MARK: - Changing folders

    /// Creates a folder, and the folders above it if need be. Returns its path.
    @discardableResult
    public func createFolder(_ path: String) throws -> String {
        let path = try Self.folderPath(path)
        guard !path.isEmpty else { throw Problem(message: "A folder needs a name.") }
        try FileManager.default.createDirectory(at: directory.appending(path: path, directoryHint: .isDirectory), withIntermediateDirectories: true)
        return path
    }

    /// Gives a folder another name, in place. Every script in it gets a new
    /// id; the result maps each old id to its new one.
    @discardableResult
    public func renameFolder(_ path: String, to name: String) throws -> [String: String] {
        let path = try Self.folderPath(path)
        let name = try Self.folderPath(name)
        guard !path.isEmpty, !name.isEmpty, !name.contains("/") else {
            throw Problem(message: "A folder's name cannot be empty or contain “/”.")
        }
        let parent = (path as NSString).deletingLastPathComponent
        let renamed = parent.isEmpty ? name : "\(parent)/\(name)"
        guard renamed != path else { return [:] }
        let destination = directory.appending(path: renamed, directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) else {
            throw Problem(message: "There is already a folder called “\(name)” here.")
        }
        let inside = scripts().map(\.id).filter { $0.hasPrefix(path + "/") }
        try FileManager.default.moveItem(at: directory.appending(path: path, directoryHint: .isDirectory), to: destination)
        return Dictionary(uniqueKeysWithValues: inside.map { ($0, renamed + $0.dropFirst(path.count)) })
    }

    /// Removes a folder that has no scripts in it, however deep.
    public func deleteFolder(_ path: String) throws {
        let path = try Self.folderPath(path)
        guard !path.isEmpty else { return }
        guard !scripts().contains(where: { $0.id.hasPrefix(path + "/") }) else {
            throw Problem(message: "“\(path)” still has scripts in it. Move them out or delete them first.")
        }
        try FileManager.default.trashItem(at: directory.appending(path: path, directoryHint: .isDirectory), resultingItemURL: nil)
    }

    /// A folder path as the store uses it: parts joined by "/", none of them
    /// empty, hidden or pointing upwards. "" is the scripts folder itself.
    public static func folderPath(_ text: String) throws -> String {
        let parts = text.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for part in parts where part.hasPrefix(".") || part.contains(":") || part.contains("\\") {
            throw Problem(message: "“\(part)” cannot be a folder name: it may not start with a dot or contain “:” or “\\”.")
        }
        return parts.joined(separator: "/")
    }

    /// Writes the example scripts when the folder does not exist yet.
    public func seedExamplesIfNeeded() throws {
        guard !FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else { return }
        for (id, source) in Examples.all {
            try save(source, to: id)
        }
    }

    // MARK: - Private

    private func url(for id: String) -> URL {
        directory.appending(path: "\(id).js")
    }

    /// An id in `folder` that no file has yet: the name itself, or with a number.
    private func unusedID(_ name: String, in folder: String) -> String {
        func id(_ name: String) -> String { folder.isEmpty ? name : "\(folder)/\(name)" }
        var candidate = id(name)
        var suffix = 2
        while FileManager.default.fileExists(atPath: url(for: candidate).path(percentEncoded: false)) {
            candidate = id("\(name)-\(suffix)")
            suffix += 1
        }
        return candidate
    }

    /// The path of something inside the scripts folder, relative to it.
    private func relativePath(of url: URL) -> String {
        let base = directory.resolvingSymlinksInPath().pathComponents
        return url.resolvingSymlinksInPath().pathComponents.dropFirst(base.count).joined(separator: "/")
    }

    /// The script files and the folders below the scripts folder. Hidden
    /// files and folders (".git") are skipped, with everything in them.
    private func contents() -> (files: [URL], folders: [String]) {
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return ([], []) }
        var files: [URL] = []
        var folders: [String] = []
        for case let url as URL in walker {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                folders.append(relativePath(of: url))
            } else if url.pathExtension.lowercased() == "js" {
                files.append(url)
            }
        }
        return (files, folders)
    }

    private func script(at url: URL) -> Script? {
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let id = (relativePath(of: url) as NSString).deletingPathExtension
        let header = ScriptHeader.parse(source)
        return Script(
            id: id,
            name: header["name"] ?? (id as NSString).lastPathComponent,
            summary: header["description"],
            shortcut: header["key"].flatMap(Shortcut.init),
            schedule: header["schedule"],
            watch: header["watch"],
            url: url
        )
    }

    static func slug(_ name: String) -> String {
        let slug = name.lowercased()
            .replacing(/[^a-z0-9]+/, with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "script" : slug
    }

    /// The source of a pipeline: a script that runs others one after
    /// another with `run()`, each handed the result of the one before.
    /// `steps` are the scripts' names, as `run()` takes them.
    public static func pipeline(name: String, steps: [String]) -> String {
        func quoted(_ text: String) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data("\"\"".utf8)
            return String(decoding: data, as: UTF8.self)
        }
        let order = steps.count <= 1 ? steps.joined() : steps.dropLast().joined(separator: ", ") + ", then " + (steps.last ?? "")
        return """
        // @name \(name)
        // @description Runs \(order); each step gets the result of the one before

        // { show: true } puts what a step publishes on show here,
        // as if you had run that step yourself.
        let data = input.data;
        \(steps.map { "data = await run(\(quoted($0)), data, { show: true });" }.joined(separator: "\n"))
        return data;

        """
    }

    static func template(name: String) -> String {
        """
        // @name \(name)
        // @description What this script does

        output.log("Dropped files:", input.files.length);
        output.json({ ok: true }).name("Status");

        """
    }
}

public enum API {
    /// TypeScript declarations of every global a script can use. This is the
    /// reference shown to people and the context given to an AI writing scripts.
    public static let typeDefinitions = resource("globals", "d.ts")

    static let prelude = resource("prelude", "js")

    private static func resource(_ name: String, _ ext: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("RhinoCore is missing its bundled resource \(name).\(ext)")
        }
        return text
    }
}
