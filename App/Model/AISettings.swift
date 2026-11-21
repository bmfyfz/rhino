import RhinoCore
import Foundation
import Observation

/// An AI provider as the user set it up. Nothing here is secret: the key is
/// in the Keychain, under the provider's id.
struct AIProviderSetup: Codable, Identifiable, Hashable {
    var id: String
    /// What the user calls it, and what a script passes as `provider`.
    var name: String
    var api: AIService.API
    /// For Anthropic's format the host; for OpenAI's the address that
    /// `/chat/completions` hangs off.
    var address: String
    var model: String
    /// False for servers that take no key, like a model running on this Mac.
    var requiresKey: Bool
    /// Added by the user, so it can be renamed, pointed elsewhere and deleted.
    var isCustom: Bool

    /// One line about what it is, for the list.
    var summary: String {
        Self.presets.first { $0.setup.id == id }?.summary ?? (URL(string: address)?.host() ?? "Your own server")
    }

    /// Where to get a key, for the providers that have such a page.
    var keyPage: URL? {
        Self.presets.first { $0.setup.id == id }?.keyPage
    }

    /// Other names a script may use for it: "claude", "gemini", "grok".
    var aliases: [String] {
        Self.presets.first { $0.setup.id == id }?.aliases ?? []
    }

    struct Preset {
        let setup: AIProviderSetup
        let summary: String
        let keyPage: URL?
        let aliases: [String]
    }

    /// The providers the app knows how to reach. Only Anthropic comes with a
    /// model chosen: model names change too often to guess the others, so
    /// they are picked from what the provider lists for the key.
    static let presets: [Preset] = [
        Preset(
            setup: AIProviderSetup(id: "anthropic", name: "Anthropic", api: .anthropic, address: "https://api.anthropic.com", model: AIService.anthropicModel, requiresKey: true, isCustom: false),
            summary: "Claude", keyPage: URL(string: "https://console.anthropic.com/settings/keys"), aliases: ["claude"]
        ),
        Preset(
            setup: AIProviderSetup(id: "openai", name: "OpenAI", api: .openAI, address: "https://api.openai.com/v1", model: "", requiresKey: true, isCustom: false),
            summary: "GPT", keyPage: URL(string: "https://platform.openai.com/api-keys"), aliases: ["gpt", "chatgpt"]
        ),
        Preset(
            setup: AIProviderSetup(id: "google", name: "Google", api: .openAI, address: "https://generativelanguage.googleapis.com/v1beta/openai", model: "", requiresKey: true, isCustom: false),
            summary: "Gemini", keyPage: URL(string: "https://aistudio.google.com/apikey"), aliases: ["gemini"]
        ),
        Preset(
            setup: AIProviderSetup(id: "xai", name: "xAI", api: .openAI, address: "https://api.x.ai/v1", model: "", requiresKey: true, isCustom: false),
            summary: "Grok", keyPage: URL(string: "https://console.x.ai"), aliases: ["grok"]
        ),
        Preset(
            setup: AIProviderSetup(id: "openrouter", name: "OpenRouter", api: .openAI, address: "https://openrouter.ai/api/v1", model: "", requiresKey: true, isCustom: false),
            summary: "Many models through one key", keyPage: URL(string: "https://openrouter.ai/keys"), aliases: []
        ),
        Preset(
            setup: AIProviderSetup(id: "ollama", name: "Ollama", api: .openAI, address: "http://localhost:11434/v1", model: "", requiresKey: false, isCustom: false),
            summary: "Models running on this Mac", keyPage: nil, aliases: ["local"]
        ),
    ]
}

/// Which AI providers are set up, and which one does what. The writer in the
/// prompt bar and `ai.ask()` in scripts each have their own choice, since
/// writing code and sorting a thousand rows rarely want the same model.
@Observable
final class AISettings {
    enum Problem: LocalizedError {
        case unknownProvider(String)
        case noAddress(String)

        var errorDescription: String? {
            switch self {
            case .unknownProvider(let name): "No AI provider called “\(name)” is set up in Settings."
            case .noAddress(let name): "Enter the address of \(name) in Settings."
            }
        }
    }

    private(set) var providers: [AIProviderSetup]
    /// The provider that writes and fixes scripts.
    var writerID: String {
        didSet { UserDefaults.standard.set(writerID, forKey: "aiWriterProvider") }
    }
    /// The provider `ai.ask()` uses when a script names none.
    var scriptID: String {
        didSet { UserDefaults.standard.set(scriptID, forKey: "aiScriptProvider") }
    }
    /// Whether a script the AI has just written is run to see if it works,
    /// and repaired if it does not.
    var triesScripts = UserDefaults.standard.object(forKey: "aiTriesScripts") as? Bool ?? true {
        didSet { UserDefaults.standard.set(triesScripts, forKey: "aiTriesScripts") }
    }
    /// How often one run may call `ai.ask()`. Every call is billed.
    var maxCallsPerRun = UserDefaults.standard.object(forKey: "aiMaxCallsPerRun") as? Int ?? Engine.defaultMaxAICalls {
        didSet { UserDefaults.standard.set(maxCallsPerRun, forKey: "aiMaxCallsPerRun") }
    }
    /// Which providers have a key saved. Kept here so that showing the list
    /// does not go to the Keychain for every row.
    private(set) var hasKey: [String: Bool] = [:]

    init() {
        let saved = UserDefaults.standard.data(forKey: "aiProviders").flatMap { try? JSONDecoder().decode([AIProviderSetup].self, from: $0) } ?? []
        // The known providers first, each with what the user changed about
        // it; then the ones they added themselves.
        var merged = AIProviderSetup.presets.map { preset in
            guard let stored = saved.first(where: { $0.id == preset.setup.id }) else { return preset.setup }
            var setup = preset.setup
            setup.model = stored.model
            // Only a server on this Mac may have moved; the others are where they are.
            if !setup.requiresKey { setup.address = stored.address }
            return setup
        }
        merged += saved.filter(\.isCustom)
        providers = merged
        writerID = UserDefaults.standard.string(forKey: "aiWriterProvider") ?? "anthropic"
        scriptID = UserDefaults.standard.string(forKey: "aiScriptProvider") ?? "anthropic"
        if !merged.contains(where: { $0.id == writerID }) { writerID = "anthropic" }
        if !merged.contains(where: { $0.id == scriptID }) { scriptID = "anthropic" }
        for provider in merged {
            hasKey[provider.id] = APIKeyStore.hasSavedKey(for: provider.id)
        }
    }

    func provider(_ id: String) -> AIProviderSetup? {
        providers.first { $0.id == id }
    }

    /// Whether a provider has everything it needs to answer.
    func isReady(_ provider: AIProviderSetup) -> Bool {
        (!provider.requiresKey || hasKey[provider.id] == true) && !provider.model.isEmpty && URL(string: provider.address)?.host() != nil
    }

    /// What is still missing, in a few words. Nil when it is ready.
    func missing(_ provider: AIProviderSetup) -> String? {
        if URL(string: provider.address)?.host() == nil { return "No address" }
        if provider.requiresKey, hasKey[provider.id] != true { return "No key" }
        if provider.model.isEmpty { return "No model chosen" }
        return nil
    }

    // MARK: - Using

    /// A provider ready to be asked, with its key. `key` stands in for the
    /// saved one while a new key is being tried out in settings.
    func service(for setup: AIProviderSetup, key: String? = nil) throws -> AIService {
        // Never a guess: a key must not go to an address the user did not give.
        guard var address = URL(string: setup.address.trimmingCharacters(in: .whitespaces)), address.host() != nil else {
            throw Problem.noAddress(setup.name)
        }
        // A gateway or a local stand-in for Anthropic's own address.
        if setup.id == "anthropic", let override = APIKeyStore.anthropicAddressOverride { address = override }
        return AIService(
            name: setup.name,
            api: setup.api,
            baseURL: address,
            apiKey: key ?? APIKeyStore.load(for: setup.id) ?? "",
            model: setup.model,
            requiresKey: setup.requiresKey
        )
    }

    /// The provider that writes scripts.
    func writer() throws -> AIService {
        try service(for: provider(writerID) ?? providers[0])
    }

    /// The provider for a script's question: the one it names, by name, id or
    /// nickname ("gemini"), or the one chosen for scripts.
    func service(named name: String?) throws -> AIService {
        guard let name = name?.trimmingCharacters(in: .whitespaces).lowercased(), !name.isEmpty else {
            return try service(for: provider(scriptID) ?? providers[0])
        }
        guard let match = providers.first(where: { $0.id == name || $0.name.lowercased() == name || $0.aliases.contains(name) }) else {
            throw Problem.unknownProvider(name)
        }
        return try service(for: match)
    }

    // MARK: - Changing

    /// Saves a provider's settings; one that is not in the list yet joins it.
    func save(_ setup: AIProviderSetup) {
        if let index = providers.firstIndex(where: { $0.id == setup.id }) {
            providers[index] = setup
        } else {
            providers.append(setup)
        }
        persist()
    }

    /// A provider of the user's own, to fill in. It joins the list when saved.
    func newCustom() -> AIProviderSetup {
        AIProviderSetup(
            id: "custom-\(UUID().uuidString.prefix(8).lowercased())", name: "", api: .openAI,
            address: "", model: "", requiresKey: true, isCustom: true
        )
    }

    func remove(_ setup: AIProviderSetup) {
        guard setup.isCustom else { return }
        APIKeyStore.save("", for: setup.id)
        hasKey[setup.id] = nil
        providers.removeAll { $0.id == setup.id }
        if writerID == setup.id { writerID = "anthropic" }
        if scriptID == setup.id { scriptID = "anthropic" }
        persist()
    }

    /// Saves a provider's key; an empty one removes it. False if the Keychain refused.
    @discardableResult
    func saveKey(_ key: String, for id: String) -> Bool {
        guard APIKeyStore.save(key, for: id) else { return false }
        hasKey[id] = APIKeyStore.hasSavedKey(for: id)
        return true
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(providers) {
            UserDefaults.standard.set(data, forKey: "aiProviders")
        }
    }
}

/// `ai.ask()` for the engine: finds the provider a question is for and asks it.
nonisolated struct ConfiguredAI: AIProvider {
    let settings: AISettings

    func answer(_ question: AIQuestion) async throws -> AIAnswer {
        // Settings, and the Keychain behind them, belong to the main actor.
        let service = try await MainActor.run { try settings.service(named: question.provider) }
        return try await service.answer(question)
    }

    func picture(_ request: AIPictureRequest) async throws -> AIPicture {
        let service = try await MainActor.run { try settings.service(named: request.provider) }
        return try await service.picture(request)
    }
}
