import RhinoCore
import ServiceManagement
import SwiftUI

/// The app's settings, one pane per subject: how the app behaves, which AI
/// it uses, the secrets scripts ask for, and the user's own functions.
struct SettingsView: View {
    enum Pane: String {
        case general, ai, secrets, functions
    }

    @AppStorage("settingsPane") private var pane = Pane.general

    var body: some View {
        TabView(selection: $pane) {
            Tab("General", systemImage: "gearshape", value: Pane.general) {
                GeneralPane()
            }
            Tab("AI", systemImage: "sparkles", value: Pane.ai) {
                AIPane()
            }
            Tab("Secrets", systemImage: "key", value: Pane.secrets) {
                SecretsPane()
            }
            Tab("Functions", systemImage: "function", value: Pane.functions) {
                FunctionsPane()
            }
        }
        // Code needs more room than a form does.
        .frame(width: pane == .functions ? 780 : 580)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open Rhino when you log in", isOn: Binding(get: { opensAtLogin }, set: setOpensAtLogin))
                if let problem {
                    Text(problem).foregroundStyle(.red)
                }
            } header: {
                Text("Schedules")
            } footer: {
                Text("Scripts with a schedule only run while Rhino is open. Closing the window keeps it running; quitting stops them.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func setOpensAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            problem = nil
        } catch {
            problem = "macOS did not accept the change: \(error.localizedDescription)"
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - AI

/// Which provider does what, and the list of providers to set up.
private struct AIPane: View {
    @Environment(AppModel.self) private var model
    @State private var editing: AIProviderSetup?

    var body: some View {
        @Bindable var ai = model.ai

        Form {
            Section {
                Picker("Write scripts with", selection: $ai.writerID) { choices }
                Picker("Answer ai.ask() with", selection: $ai.scriptID) { choices }
            } header: {
                Text("Use")
            } footer: {
                usageNote
            }

            Section {
                Toggle("Try scripts after writing them", isOn: $ai.triesScripts)
                Stepper(value: $ai.maxCallsPerRun, in: 1...1000, step: ai.maxCallsPerRun < 50 ? 5 : 50) {
                    LabeledContent("AI calls a script may make per run", value: "\(ai.maxCallsPerRun)")
                }
            } footer: {
                Text("With trying on, a script the AI wrote is run straight away, and if it fails the error goes back to the AI for up to two repairs. The limit stops a script in a loop from spending your money unnoticed; a run that reaches it fails.")
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(ai.providers) { provider in
                    ProviderRow(provider: provider, missing: ai.missing(provider)) {
                        editing = provider
                    }
                }
                Button("Add Provider…") {
                    editing = ai.newCustom()
                }
            } header: {
                Text("Providers")
            } footer: {
                Text("Keys are kept in your Mac’s Keychain. Requests go straight from this Mac to the provider and are billed to your key there.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(item: $editing) { provider in
            ProviderEditor(setup: provider, isNew: model.ai.provider(provider.id) == nil)
        }
        .onChange(of: ai.writerID) { model.aiSettingsChanged() }
    }

    @ViewBuilder private var choices: some View {
        ForEach(model.ai.providers) { provider in
            Text(model.ai.isReady(provider) ? provider.name : "\(provider.name) (not set up)")
                .tag(provider.id)
        }
    }

    /// Says what is wrong with the choices above, or what they mean.
    @ViewBuilder private var usageNote: some View {
        let ai = model.ai
        let unready = [ai.writerID, ai.scriptID]
            .compactMap(ai.provider)
            .filter { !ai.isReady($0) }
            .map(\.name)
        if let name = unready.first {
            Label("\(name) is not set up yet. Set it up below, or choose another provider.", systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .foregroundStyle(.secondary)
        } else {
            Text("The first writes and fixes scripts for you. The second answers the questions scripts ask while they run; a script can also name a provider itself.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct ProviderRow: View {
    let provider: AIProviderSetup
    /// What it still needs, or nil when it is ready.
    let missing: String?
    let edit: () -> Void

    var body: some View {
        LabeledContent {
            if let missing {
                Text(missing)
                    .foregroundStyle(.tertiary)
            } else {
                Label {
                    Text(provider.model)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .help("Ready to use")
            }
            Button(missing == nil ? "Edit…" : "Set Up…", action: edit)
                .controlSize(.small)
        } label: {
            Text(provider.name.isEmpty ? "Unnamed" : provider.name)
            Text(provider.summary)
        }
    }
}

/// One provider's settings: where it is, the key, and the model to use.
private struct ProviderEditor: View {
    private enum Check: Equatable {
        case loading
        case found(Int)
        case failed(String)
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var setup: AIProviderSetup
    let isNew: Bool
    /// A key typed here but not saved yet.
    @State private var key = ""
    @State private var removesKey = false
    @State private var models: [String] = []
    @State private var check: Check?
    @State private var problem: String?
    @State private var confirmsDeleting = false

    private var hasSavedKey: Bool {
        model.ai.hasKey[setup.id] == true && !removesKey
    }

    var body: some View {
        VStack(spacing: 0) {
            // A sheet has no title bar, so it says itself what it is about.
            VStack(alignment: .leading, spacing: 2) {
                Text(isNew ? "New Provider" : setup.name)
                    .font(.headline)
                Text(isNew ? "Any server that speaks OpenAI’s or Anthropic’s format" : setup.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .top], 20)

            Form {
                if setup.isCustom {
                    Section {
                        TextField("Name", text: $setup.name, prompt: Text("What to call it"))
                        TextField("Address", text: $setup.address, prompt: Text(verbatim: "https://example.com/v1"))
                            .autocorrectionDisabled()
                        Picker("Format", selection: $setup.api) {
                            Text("OpenAI (most providers)").tag(AIService.API.openAI)
                            Text("Anthropic").tag(AIService.API.anthropic)
                        }
                        Toggle("Needs an API key", isOn: $setup.requiresKey)
                    } footer: {
                        Text(setup.api == .openAI
                            ? "The address is the part before “/chat/completions”; it usually ends in “/v1”."
                            : "The address is the part before “/v1/messages”.")
                            .foregroundStyle(.secondary)
                    }
                } else if !setup.requiresKey {
                    Section {
                        TextField("Address", text: $setup.address, prompt: Text(verbatim: "http://localhost:11434/v1"))
                            .autocorrectionDisabled()
                    }
                }

                if setup.requiresKey {
                    Section {
                        SecureField("API key", text: $key, prompt: Text(hasSavedKey ? "A key is saved. Enter a new one to replace it." : "Paste your key"))
                        if hasSavedKey || setup.keyPage != nil {
                            HStack {
                                if hasSavedKey {
                                    Button("Remove Saved Key", role: .destructive) {
                                        removesKey = true
                                        key = ""
                                    }
                                }
                                Spacer()
                                if let page = setup.keyPage {
                                    Link("Get a key", destination: page)
                                }
                            }
                        }
                    }
                }

                Section {
                    LabeledContent("Model") {
                        TextField("Model", text: $setup.model, prompt: Text("Choose one, or type its name"))
                            .labelsHidden()
                            .autocorrectionDisabled()
                        Menu("Choose") {
                            let shown = matchingModels
                            ForEach(shown.prefix(40), id: \.self) { name in
                                Button(name) { setup.model = name }
                            }
                            if shown.count > 40 {
                                Divider()
                                Text("\(shown.count - 40) more. Type part of a name to narrow the list.")
                            }
                        }
                        .fixedSize()
                        .disabled(models.isEmpty)
                    }
                    HStack(spacing: 8) {
                        Button("Load Models", action: loadModels)
                            .disabled(check == .loading)
                        switch check {
                        case .loading:
                            ProgressView().controlSize(.small)
                        case .found(let count):
                            Label(count == 1 ? "1 model found" : "\(count) models found", systemImage: "checkmark.circle.fill")
                                .symbolRenderingMode(.multicolor)
                                .foregroundStyle(.secondary)
                        case .failed(let message):
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .symbolRenderingMode(.multicolor)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        case nil:
                            EmptyView()
                        }
                    }
                } footer: {
                    Text("Load Models asks the provider which models your key can use. It is also a quick check that the key and address work.")
                        .foregroundStyle(.secondary)
                }

                if let problem {
                    Text(problem).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                if setup.isCustom, !isNew {
                    Button("Delete Provider…", role: .destructive) { confirmsDeleting = true }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Done", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(setup.isCustom && setup.name.allSatisfy(\.isWhitespace))
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 500)
        .confirmationDialog("Delete “\(setup.name)”?", isPresented: $confirmsDeleting) {
            Button("Delete Provider", role: .destructive) {
                model.ai.remove(setup)
                model.aiSettingsChanged()
                dismiss()
            }
        } message: {
            Text("Its saved key is removed too. Scripts that name it will fail until you point them at another provider.")
        }
    }

    /// The loaded models that contain what is typed in the field, or all of
    /// them while the field holds one of them exactly.
    private var matchingModels: [String] {
        let typed = setup.model.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty, !models.contains(typed) else { return models }
        let matches = models.filter { $0.localizedCaseInsensitiveContains(typed) }
        return matches.isEmpty ? models : matches
    }

    private func loadModels() {
        let service: AIService
        do {
            // What is typed is tried before it is saved, so a wrong key never replaces a good one.
            service = try model.ai.service(for: setup, key: key.isEmpty ? (removesKey ? "" : nil) : key)
        } catch {
            check = .failed(error.localizedDescription)
            return
        }
        check = .loading
        Task {
            do {
                let found = try await service.models()
                models = found
                check = .found(found.count)
            } catch {
                models = []
                check = .failed(error.localizedDescription)
            }
        }
    }

    private func save() {
        setup.name = setup.name.trimmingCharacters(in: .whitespaces)
        setup.address = setup.address.trimmingCharacters(in: .whitespaces)
        setup.model = setup.model.trimmingCharacters(in: .whitespaces)

        let ai = model.ai
        if setup.isCustom, ai.providers.contains(where: { $0.id != setup.id && $0.name.lowercased() == setup.name.lowercased() }) {
            problem = "Another provider is already called “\(setup.name)”."
            return
        }
        if !key.allSatisfy(\.isWhitespace) {
            guard ai.saveKey(key, for: setup.id) else {
                problem = "The Keychain did not accept the key."
                return
            }
        } else if removesKey {
            ai.saveKey("", for: setup.id)
        }
        ai.save(setup)
        model.aiSettingsChanged()
        dismiss()
    }
}

// MARK: - Secrets

private struct SecretsPane: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var value = ""
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                ForEach(model.secretNames, id: \.self) { name in
                    LabeledContent(name) {
                        Text(String(repeating: "•", count: 8))
                            .foregroundStyle(.tertiary)
                        Button("Remove", role: .destructive) { model.removeSecret(named: name) }
                            .controlSize(.small)
                    }
                }
                HStack {
                    TextField("Name", text: $name, prompt: Text("NAME"))
                        .labelsHidden()
                        .frame(maxWidth: 180)
                    SecureField("Value", text: $value, prompt: Text("Value"))
                        .labelsHidden()
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(name.allSatisfy(\.isWhitespace) || value.isEmpty)
                }
                if let problem {
                    Text(problem).foregroundStyle(.red)
                }
            } footer: {
                Text("Keys and tokens your scripts use. They are kept in your Keychain and shared by every script that asks for the same name. A script asks for a missing one the first time you run it.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func add() {
        guard !name.allSatisfy(\.isWhitespace), !value.isEmpty else { return }
        if model.saveSecret(value, named: name) {
            name = ""
            value = ""
            problem = nil
        } else {
            problem = "The Keychain did not accept the secret."
        }
    }
}
