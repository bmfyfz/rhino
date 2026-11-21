import Foundation
import JavaScriptCore

// `input.ask()`, `input.form()`, `input.file()` and `secrets.get()`: everything that may stop to ask the user.
extension Execution {
    // MARK: - Questions

    func ask(runID: String, arguments: JSValue, callback: JSValue) {
        guard let id = register(callback) else { return }
        let message = arguments.forProperty("message").toString() ?? ""
        var kind = PromptRequest.Kind(rawValue: arguments.forProperty("type").toString() ?? "") ?? .text
        if kind == .form { kind = .text }
        let fallback = arguments.forProperty("default")
        let hasDefault = arguments.forProperty("hasDefault").toBool()

        guard interactive else {
            if hasDefault, kind != .file {
                emit(.log(LogEntry(id: UUID(), runID: runID, date: Date(), level: .debug, message: "\"\(message)\" used its default: nobody is here to answer")))
                return settle(id, value: fallback?.toObject())
            }
            return settle(id, error: "\"\(message)\" needs an answer, but this run is unattended."
                + (kind == .file ? "" : " Give input.ask() a default."))
        }

        let options = (arguments.forProperty("options").toArray() ?? []).map { "\($0)" }
        if kind == .secret { secretQuestions.insert(id) }
        let request = PromptRequest(
            id: id,
            runID: runID,
            message: message,
            kind: kind,
            options: options,
            placeholder: arguments.forProperty("placeholder").toString() ?? "",
            defaultText: hasDefault ? fallback?.toString() : nil,
            fields: [],
            detail: "",
            submitLabel: "",
            secretName: nil,
            reply: { [weak self] answer in
                Task { await self?.answer(id, with: answer) }
            }
        )
        emit(.prompt(request))
    }

    func form(runID: String, arguments: JSValue, callback: JSValue) {
        guard let id = register(callback) else { return }
        let descriptions = arguments.forProperty("fields").toArray() as? [[String: Any]] ?? []
        let fields = descriptions.compactMap { FormField(json: $0) }
        let defaults = Dictionary(fields.map { ($0.id, $0.defaultValue) }, uniquingKeysWith: { first, _ in first })

        guard interactive else {
            // Nobody is here to fill it in, so the defaults have to be enough.
            if let missing = fields.first(where: { !$0.accepts(defaults[$0.id] ?? .none) }) {
                return settle(id, error: "The form needs \"\(missing.label)\", but this run is unattended. Give every required field a default.")
            }
            return settle(id, value: FormCoding.encode(defaults, fields: fields))
        }

        forms[id] = fields
        let request = PromptRequest(
            id: id,
            runID: runID,
            message: arguments.forProperty("title").toString() ?? "",
            kind: .form,
            options: [],
            placeholder: "",
            defaultText: nil,
            fields: fields,
            detail: arguments.forProperty("description").toString() ?? "",
            submitLabel: arguments.forProperty("submit").toString() ?? "",
            secretName: nil,
            reply: { [weak self] answer in
                Task { await self?.answer(id, with: answer) }
            }
        )
        emit(.prompt(request))
    }

    func answer(_ id: UUID, with answer: PromptRequest.Answer) {
        guard pending[id] != nil else { return }
        emit(.promptResolved(id: id))
        switch answer {
        case .text(let text):
            if let asked = askedSecrets.removeValue(forKey: id) {
                guard !text.isEmpty else {
                    return settle(id, error: "Nothing was entered for “\(asked.name)”.")
                }
                secrets.save(text, named: asked.name)
                // Whoever the user typed it in for may keep using it.
                grants?.allow(script: asked.script, secret: asked.name)
                masker.add(text)
            } else if secretQuestions.remove(id) != nil {
                masker.add(text)
            }
            settle(id, value: text)
        case .number(let number): settle(id, value: number)
        case .bool(let flag):
            guard let wanted = secretPermissions.removeValue(forKey: id) else {
                return settle(id, value: flag)
            }
            guard flag, let value = secrets.value(named: wanted.name), !value.isEmpty else {
                return settle(id, error: "You did not allow this script to use the secret “\(wanted.name)”.")
            }
            grants?.allow(script: wanted.script, secret: wanted.name)
            masker.add(value)
            settle(id, value: value)
        case .file(let url):
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            settle(id, value: ["name": url.lastPathComponent, "path": url.path(percentEncoded: false), "size": size] as [String: Any])
        case .form(let values):
            let fields = forms.removeValue(forKey: id) ?? []
            // What was typed into a secret field is a secret from here on.
            for field in fields where field.kind == .secret {
                if case .text(let typed) = values[field.id] { masker.add(typed) }
            }
            settle(id, value: FormCoding.encode(values, fields: fields))
        case .cancelled: settle(id, error: "Cancelled: the question was dismissed")
        }
    }

    // MARK: - Secrets

    /// A saved secret is handed over at once to a script that may read it;
    /// for any other script the user is asked first, once. One that is not
    /// saved yet is asked for, once, and kept. With nobody to ask, the run
    /// fails and says what is missing.
    func secret(runID: String, arguments: JSValue, callback: JSValue) {
        guard let id = register(callback) else { return }
        let name = (arguments.forProperty("name").toString() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return settle(id, error: "secrets.get() needs the name of the secret.")
        }
        let script = scriptOfRun[runID] ?? ""
        if let value = secrets.value(named: name), !value.isEmpty {
            guard let grants, !grants.allows(script: script, secret: name) else {
                masker.add(value)
                return settle(id, value: value)
            }
            let title = provider.script(named: script).flatMap { ScriptHeader.parse($0.source)["name"] } ?? script
            guard interactive else {
                return settle(id, error: "“\(title)” has not been allowed to use the saved secret “\(name)”. Run it once by hand to be asked.")
            }
            secretPermissions[id] = SecretRequest(name: name, script: script)
            return emit(.prompt(PromptRequest(
                id: id,
                runID: runID,
                message: "Allow “\(title)” to use your saved secret “\(name)”?",
                kind: .confirm,
                options: [],
                placeholder: "",
                // Answering without looking should not hand a secret over.
                defaultText: "false",
                fields: [],
                detail: "",
                submitLabel: "",
                secretName: name,
                reply: { [weak self] answer in
                    Task { await self?.answer(id, with: answer) }
                }
            )))
        }
        guard interactive else {
            return settle(id, error: "The secret “\(name)” is not saved yet. Add it in Settings, or run this script once by hand to be asked for it.")
        }

        let description = arguments.forProperty("description").toString() ?? ""
        askedSecrets[id] = SecretRequest(name: name, script: script)
        emit(.prompt(PromptRequest(
            id: id,
            runID: runID,
            message: description.isEmpty ? name : description,
            kind: .secret,
            options: [],
            placeholder: name,
            defaultText: nil,
            fields: [],
            detail: "",
            submitLabel: "",
            secretName: name,
            reply: { [weak self] answer in
                Task { await self?.answer(id, with: answer) }
            }
        )))
    }

    /// The text with every secret this run handled blanked out.
    func masked(_ text: String) -> String {
        masker.mask(text)
    }
}
