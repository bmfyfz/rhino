import RhinoCore
import Foundation
import Security

/// Where the AI providers' API keys live: the Mac's Keychain, one entry per
/// provider, so a key is never in a file or in the app's preferences.
enum APIKeyStore {
    private static let service = "app.rhino.Rhino"

    /// Anthropic's entry keeps the name it had when it was the only one.
    private static func account(for provider: String) -> String {
        provider == "anthropic" ? "anthropic-api-key" : "ai-key-\(provider)"
    }

    /// The saved key. For Anthropic, failing that, `ANTHROPIC_API_KEY` from
    /// the environment, which is handy when the app is started from a terminal.
    static func load(for provider: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account(for: provider),
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let key = String(data: data, encoding: .utf8),
           !key.isEmpty {
            return key
        }
        guard provider == "anthropic" else { return nil }
        let fromEnvironment = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
        return fromEnvironment.isEmpty ? nil : fromEnvironment
    }

    /// Whether a key was saved in the Keychain (as opposed to coming from the
    /// environment). Does not read the key itself.
    static func hasSavedKey(for provider: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account(for: provider),
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Replaces the saved key. An empty key removes it. Returns false if the Keychain refused.
    @discardableResult
    static func save(_ key: String, for provider: String) -> Bool {
        let identity: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account(for: provider),
        ]
        SecItemDelete(identity as CFDictionary)

        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        var item = identity
        item[kSecAttrLabel] = "Rhino AI key: \(provider)"
        item[kSecValueData] = Data(trimmed.utf8)
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    /// `ANTHROPIC_BASE_URL` points the app at a gateway or a local stand-in
    /// instead of Anthropic's own address.
    static var anthropicAddressOverride: URL? {
        ProcessInfo.processInfo.environment["ANTHROPIC_BASE_URL"].flatMap(URL.init(string:))
    }
}

/// The secrets scripts ask for with `secrets.get()`, kept in the Mac's
/// Keychain: one entry per name, shared by every script.
struct KeychainSecretStore: SecretStore {
    private static let service = "app.rhino.Rhino.secrets"

    func value(named name: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: name,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func save(_ value: String, named name: String) -> Bool {
        remove(named: name)
        let item: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: name,
            kSecAttrLabel: "Rhino secret: \(name)",
            kSecValueData: Data(value.utf8),
        ]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    func remove(named name: String) {
        let identity: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: name,
        ]
        SecItemDelete(identity as CFDictionary)
    }

    /// The names of the saved secrets, never their values.
    func names() -> [String] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
              let entries = items as? [[CFString: Any]] else { return [] }
        return entries.compactMap { $0[kSecAttrAccount] as? String }.sorted()
    }
}
