import Foundation
import Synchronization

// What outlives a run: secrets the user saved once, and what each script
// chose to remember. The engine only knows these protocols; an app decides
// where the data really lives (the Keychain, a folder).

/// Passwords, API keys and tokens, by name. One saved token can serve
/// several scripts; `SecretGrants` decides which.
public protocol SecretStore: Sendable {
    func value(named name: String) -> String?
    /// Returns false when the secret could not be saved.
    @discardableResult func save(_ value: String, named name: String) -> Bool
}

/// Which scripts may read which saved secrets. A script is granted the
/// secrets it asked the user for itself; for any other saved secret the
/// user is asked first, once. So a script that was just written or
/// downloaded cannot quietly pick up a token another script saved.
public protocol SecretGrants: Sendable {
    func allows(script: String, secret: String) -> Bool
    func allow(script: String, secret: String)
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

/// Grants kept only while the process lives. For tests.
public final class InMemorySecretGrants: SecretGrants {
    /// Script ids by secret name.
    private let scripts: Mutex<[String: Set<String>]>

    public init(_ scripts: [String: Set<String>] = [:]) {
        self.scripts = Mutex(scripts)
    }

    public func allows(script: String, secret: String) -> Bool {
        scripts.withLock { $0[secret]?.contains(script) == true }
    }

    public func allow(script: String, secret: String) {
        scripts.withLock { _ = $0[secret, default: []].insert(script) }
    }
}

/// Grants as one readable JSON file: the ids of the scripts that may read
/// each secret, by the secret's name. Only names are kept here, never values.
public final class FileSecretGrants: SecretGrants {
    private let file: URL
    /// Runs and the app's settings may touch the file at once; they take turns.
    private let lock = NSLock()

    public init(file: URL) {
        self.file = file
    }

    public func allows(script: String, secret: String) -> Bool {
        lock.withLock { load()[secret]?.contains(script) == true }
    }

    public func allow(script: String, secret: String) {
        change { $0[secret, default: []].insert(script) }
    }

    /// Takes a secret away from one script. It is asked about again the
    /// next time the script wants it.
    public func revoke(script: String, secret: String) {
        change { $0[secret]?.remove(script) }
    }

    /// The scripts that may read each secret, by the secret's name.
    public func all() -> [String: [String]] {
        lock.withLock { load().mapValues { $0.sorted() } }
    }

    /// Forgets who could read a secret, for when the secret itself is removed.
    public func forget(secret: String) {
        change { $0[secret] = nil }
    }

    /// Forgets everything a script was allowed, for when the script is
    /// deleted: a new script that happens to get its id starts with nothing.
    public func forget(script: String) {
        change { grants in
            for secret in grants.keys { grants[secret]?.remove(script) }
        }
    }

    /// Carries what a script was allowed over to its new id after it was moved.
    public func rename(script: String, to renamed: String) {
        change { grants in
            for secret in grants.keys where grants[secret]?.remove(script) != nil {
                grants[secret]?.insert(renamed)
            }
        }
    }

    // MARK: - Private

    private func load() -> [String: Set<String>] {
        guard let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode([String: Set<String>].self, from: data) else { return [:] }
        return saved
    }

    /// A change that cannot be written is lost, and the user is asked again.
    private func change(_ edit: (inout [String: Set<String>]) -> Void) {
        lock.withLock {
            var grants = load()
            edit(&grants)
            let kept = grants.filter { !$0.value.isEmpty }.mapValues { $0.sorted() }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(kept) else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
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
