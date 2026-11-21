import Foundation
import Synchronization

// What outlives a run: secrets the user saved once, and what each script
// chose to remember. The engine only knows these protocols; an app decides
// where the data really lives (the Keychain, a folder).

/// Passwords, API keys and tokens, by name. Shared by all scripts, so one
/// saved token serves every script that asks for it.
public protocol SecretStore: Sendable {
    func value(named name: String) -> String?
    /// Returns false when the secret could not be saved.
    @discardableResult func save(_ value: String, named name: String) -> Bool
}

/// What scripts remember between runs. Every script has its own keys, and
/// values are JSON text.
public protocol MemoryStore: Sendable {
    func json(forKey key: String, script: String) -> String?
    func set(json: String, forKey key: String, script: String) throws
    func remove(key: String, script: String) throws
    func keys(script: String) -> [String]
    /// Forgets everything a script remembered.
    func clear(script: String) throws
}

/// Secrets kept only while the process lives. For tests, and the engine's
/// default when an app supplies no store.
public final class InMemorySecretStore: SecretStore {
    private let values: Mutex<[String: String]>

    public init(_ values: [String: String] = [:]) {
        self.values = Mutex(values)
    }

    public func value(named name: String) -> String? {
        values.withLock { $0[name] }
    }

    public func save(_ value: String, named name: String) -> Bool {
        values.withLock { $0[name] = value }
        return true
    }
}

/// Memory kept only while the process lives.
public final class InMemoryMemoryStore: MemoryStore {
    private let scripts = Mutex<[String: [String: String]]>([:])

    public init() {}

    public func json(forKey key: String, script: String) -> String? {
        scripts.withLock { $0[script]?[key] }
    }

    public func set(json: String, forKey key: String, script: String) {
        scripts.withLock { $0[script, default: [:]][key] = json }
    }

    public func remove(key: String, script: String) {
        scripts.withLock { $0[script]?[key] = nil }
    }

    public func keys(script: String) -> [String] {
        scripts.withLock { ($0[script] ?? [:]).keys.sorted() }
    }

    public func clear(script: String) {
        scripts.withLock { $0[script] = nil }
    }
}

/// Memory as one readable JSON file per script in a folder, so what a script
/// remembers survives quitting and can be looked at, backed up or deleted
/// like any other file.
public final class FileMemoryStore: MemoryStore {
    private let directory: URL
    /// Two runs may touch the same file at once; reads and writes take turns.
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
    }

    public func json(forKey key: String, script: String) -> String? {
        lock.withLock {
            guard let value = load(script)[key],
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
    }

    public func set(json: String, forKey key: String, script: String) throws {
        let value = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
        try lock.withLock {
            var contents = load(script)
            contents[key] = value
            try save(contents, script)
        }
    }

    public func remove(key: String, script: String) throws {
        try lock.withLock {
            var contents = load(script)
            guard contents.removeValue(forKey: key) != nil else { return }
            try save(contents, script)
        }
    }

    public func keys(script: String) -> [String] {
        lock.withLock { load(script).keys.sorted() }
    }

    public func clear(script: String) throws {
        try lock.withLock {
            let url = file(for: script)
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Carries what a script remembers over to its new id after it was moved.
    public func rename(script: String, to renamed: String) {
        lock.withLock {
            let old = file(for: script)
            guard FileManager.default.fileExists(atPath: old.path(percentEncoded: false)) else { return }
            try? FileManager.default.removeItem(at: file(for: renamed))
            try? FileManager.default.moveItem(at: old, to: file(for: renamed))
        }
    }

    // MARK: - Private

    private func file(for script: String) -> URL {
        let name = script.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-_"))) ?? "script"
        return directory.appending(path: "\(name).json")
    }

    private func load(_ script: String) -> [String: Any] {
        guard let data = try? Data(contentsOf: file(for: script)) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func save(_ contents: [String: Any], _ script: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: file(for: script), options: .atomic)
    }
}
