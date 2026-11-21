import AppKit
import RhinoCore
import SwiftUI
import UniformTypeIdentifiers

/// The form a script asked for with `input.form()`, as a sheet over the
/// window. It is a standard grouped form, so every field is the system's own
/// control for its kind.
struct FormSheet: View {
    let session: RunSession
    let prompt: PromptRequest
    @State private var values: [String: FormValue]

    init(session: RunSession, prompt: PromptRequest) {
        self.session = session
        self.prompt = prompt
        _values = State(initialValue: Dictionary(prompt.fields.map { ($0.id, $0.defaultValue) }, uniquingKeysWith: { first, _ in first }))
    }

    var body: some View {
        Form {
            Section {
                ForEach(prompt.fields) { field in
                    control(for: field)
                }
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(prompt.message.isEmpty ? session.script.name : prompt.message)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                    if !prompt.detail.isEmpty {
                        Text(prompt.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .textCase(nil)
                .padding(.bottom, 4)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) { session.answer(prompt, with: .cancelled) }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(prompt.submitLabel.isEmpty ? "Continue" : prompt.submitLabel) {
                    session.answer(prompt, with: .form(values))
                }
                .disabled(!isComplete)
            }
        }
        // Only the two buttons close the form, so a run is never left waiting
        // on a form that is no longer on screen.
        .interactiveDismissDisabled()
    }

    private var isComplete: Bool {
        prompt.fields.allSatisfy { $0.accepts(values[$0.id] ?? .none) }
    }

    // MARK: - Fields

    @ViewBuilder private func control(for field: FormField) -> some View {
        switch field.kind {
        case .text:
            TextField(text: text(field), prompt: placeholder(field)) { label(field) }
        case .multiline:
            TextField(text: text(field), prompt: placeholder(field), axis: .vertical) { label(field) }
                .lineLimit(3...8)
        case .secret:
            SecureField(text: text(field), prompt: placeholder(field)) { label(field) }
        case .number:
            TextField(value: number(field), format: .number, prompt: placeholder(field)) { label(field) }
        case .toggle:
            Toggle(isOn: flag(field)) { label(field) }
        case .select:
            Picker(selection: option(field)) {
                if !field.isRequired {
                    Text("None").tag(-1)
                }
                ForEach(field.options.indices, id: \.self) { index in
                    Text(field.options[index]).tag(index)
                }
            } label: {
                label(field)
            }
        case .date:
            DatePicker(selection: date(field), displayedComponents: .date) { label(field) }
        case .dateTime:
            DatePicker(selection: date(field), displayedComponents: [.date, .hourAndMinute]) { label(field) }
        case .time:
            DatePicker(selection: date(field), displayedComponents: .hourAndMinute) { label(field) }
        case .file:
            LabeledContent {
                if case .file(let url) = values[field.id] {
                    Text(url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                Button("Choose…") { chooseFile(for: field) }
            } label: {
                label(field)
            }
        }
    }

    @ViewBuilder private func label(_ field: FormField) -> some View {
        Text(field.label)
        if !field.help.isEmpty {
            Text(field.help)
        }
    }

    private func placeholder(_ field: FormField) -> Text? {
        if !field.placeholder.isEmpty { return Text(field.placeholder) }
        return field.isRequired ? Text("Required") : nil
    }

    private func chooseFile(for field: FormField) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.message = field.label
        let types = field.options.compactMap { UTType(filenameExtension: $0) }
        if !types.isEmpty { panel.allowedContentTypes = types }
        if panel.runModal() == .OK, let url = panel.url {
            values[field.id] = .file(url)
        }
    }

    // MARK: - Bindings

    private func text(_ field: FormField) -> Binding<String> {
        Binding {
            if case .text(let text) = values[field.id] { text } else { "" }
        } set: {
            values[field.id] = .text($0)
        }
    }

    private func number(_ field: FormField) -> Binding<Double?> {
        Binding {
            if case .number(let number) = values[field.id] { number } else { nil }
        } set: {
            values[field.id] = $0.map(FormValue.number) ?? FormValue.none
        }
    }

    private func flag(_ field: FormField) -> Binding<Bool> {
        Binding {
            if case .bool(let flag) = values[field.id] { flag } else { false }
        } set: {
            values[field.id] = .bool($0)
        }
    }

    /// -1 stands for "nothing chosen", which only optional fields offer.
    private func option(_ field: FormField) -> Binding<Int> {
        Binding {
            if case .option(let index) = values[field.id] { index } else { -1 }
        } set: {
            values[field.id] = $0 >= 0 ? FormValue.option($0) : FormValue.none
        }
    }

    private func date(_ field: FormField) -> Binding<Date> {
        Binding {
            if case .date(let date) = values[field.id] { date } else { Date() }
        } set: {
            values[field.id] = .date($0)
        }
    }
}

extension FormField {
    /// How a submitted value reads in the output, e.g. "Format: CSV".
    func describe(_ value: FormValue) -> String {
        switch value {
        case .none: "–"
        case .text(let text): kind == .secret ? String(repeating: "•", count: 8) : text
        case .number(let number): number.formatted()
        case .bool(let flag): flag ? "Yes" : "No"
        case .option(let index): options.indices.contains(index) ? options[index] : "–"
        case .file(let url): url.lastPathComponent
        case .date(let date):
            switch kind {
            case .time: date.formatted(date: .omitted, time: .shortened)
            case .dateTime: date.formatted(date: .abbreviated, time: .shortened)
            default: date.formatted(date: .abbreviated, time: .omitted)
            }
        }
    }
}
