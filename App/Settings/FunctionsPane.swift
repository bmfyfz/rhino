import RhinoCore
import SwiftUI

/// The user's own functions: files of JavaScript whose top-level functions
/// and values every script can use, next to the built-in API. Files are
/// listed on the left and edited on the right; an edit takes effect when it
/// is saved, and only code that can be used can be saved, so half-typed
/// functions never reach a script that is running on a schedule.
struct FunctionsPane: View {
    @Environment(AppModel.self) private var model
    @State private var files: [SharedFile] = []
    @State private var selection: String?
    /// Edits not saved yet, by file. Kept while another file is looked at.
    @State private var drafts: [String: String] = [:]
    @State private var confirmsDeleting = false
    @State private var failure: String?

    private var selected: SharedFile? {
        files.first { $0.id == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Functions and values you define here can be used in every script, like the built-in ones. A file can call the built-in API, and the functions of the files listed above it.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 0) {
                fileList
                    .frame(width: 180)
                Hairline(.vertical)
                editor
            }
            .frame(height: 400)
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))

            if let failure {
                Text(failure).foregroundStyle(.red)
            }
        }
        .padding(20)
        .onAppear(perform: reload)
        .confirmationDialog("Delete “\(selection ?? "").js”?", isPresented: $confirmsDeleting) {
            Button("Move to Trash", role: .destructive, action: deleteSelected)
        } message: {
            Text("Scripts that use its functions will fail until you define them elsewhere.")
        }
    }

    // MARK: - The list of files

    private var fileList: some View {
        VStack(spacing: 0) {
            List(files, selection: $selection) { file in
                HStack(spacing: 6) {
                    Text("\(file.id).js")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    if drafts[file.id] != nil {
                        // As a document window marks itself: edited, not saved.
                        Circle()
                            .fill(.secondary)
                            .frame(width: 6, height: 6)
                            .help("Has changes that are not saved")
                    }
                }
                .tag(file.id)
            }
            Hairline(.horizontal)
            HStack(spacing: 2) {
                Button(action: add) {
                    Image(systemName: "plus").frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .help("Add a file")
                .accessibilityLabel("Add File")
                Button { confirmsDeleting = true } label: {
                    Image(systemName: "minus").frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .help("Delete the selected file")
                .accessibilityLabel("Delete File")
                .disabled(selection == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 6)
            .frame(height: 30)
        }
    }

    // MARK: - The selected file

    @ViewBuilder private var editor: some View {
        if let file = selected {
            let text = drafts[file.id] ?? file.source
            let problem = SharedLibrary.problem(in: SharedFile(id: file.id, source: text), among: files)
            VStack(spacing: 0) {
                CodeEditor(text: Binding(
                    get: { drafts[file.id] ?? file.source },
                    set: { drafts[file.id] = $0 == file.source ? nil : $0 }
                ))
                // A different file is a different document: its own undo, its own scroll.
                .id(file.id)
                Hairline(.horizontal)
                HStack(spacing: 8) {
                    status(for: text, problem: problem)
                    Spacer(minLength: 8)
                    Button("Revert") { drafts[file.id] = nil }
                        .disabled(drafts[file.id] == nil)
                    Button("Save") { save(file, text) }
                        .keyboardShortcut("s")
                        .disabled(drafts[file.id] == nil || problem != nil)
                }
                .controlSize(.small)
                .padding(.horizontal, 10)
                .frame(height: 34)
            }
        } else {
            ContentUnavailableView {
                Label("No Functions Yet", systemImage: "function")
            } description: {
                Text("Add a file to define functions that every script can use.")
            } actions: {
                Button("Add File", action: add)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// What the file gives scripts, or what stops it from being saved.
    @ViewBuilder private func status(for text: String, problem: String?) -> some View {
        if let problem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .help(problem)
        } else {
            let names = SharedLibrary.names(definedIn: text)
            Text(names.isEmpty ? "Defines nothing yet" : "Defines \(names.joined(separator: ", "))")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    // MARK: - Actions

    private func reload() {
        files = model.functions.sharedFiles()
        if selected == nil { selection = files.first?.id }
    }

    private func add() {
        do {
            let file = try model.functions.create(named: "functions")
            failure = nil
            reload()
            selection = file.id
        } catch {
            failure = "Could not add a file: \(error.localizedDescription)"
        }
    }

    private func save(_ file: SharedFile, _ text: String) {
        do {
            try model.functions.save(text, to: file.id)
            drafts[file.id] = nil
            failure = nil
            reload()
        } catch {
            failure = "Could not save \(file.id).js: \(error.localizedDescription)"
        }
    }

    private func deleteSelected() {
        guard let id = selection else { return }
        do {
            try model.functions.delete(id)
            drafts[id] = nil
            selection = nil
            failure = nil
            reload()
        } catch {
            failure = "Could not move \(id).js to the Trash: \(error.localizedDescription)"
        }
    }
}
