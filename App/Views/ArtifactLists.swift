import AppKit
import RhinoCore
import SwiftUI

/// The inventory of a run, for the panel under the editor: everything that
/// went in (files, filled-in forms) and everything that came out (published
/// items, saved files), as two lists side by side. Clicking a row jumps to it
/// in the preview.
struct ArtifactLists: View {
    @Environment(AppModel.self) private var model
    let script: Script
    let session: RunSession?
    @State private var isDropTargeted = false

    var body: some View {
        let inputFiles = model.inputFiles[script.id] ?? []
        // What went in: the dropped files, then the forms that were filled in.
        let inputs = inputFiles.map(ArtifactID.file) + (session?.submittedForms ?? []).map(ArtifactID.form)
        // What came out: the values the script published, then the files it saved.
        let outputs = (session?.outputIDs ?? []).map(ArtifactID.output) + (session?.files ?? []).map(ArtifactID.file)

        ScrollView {
            HStack(alignment: .top, spacing: 16) {
                SidebarSection("Input") {
                    Button("Add Files…", systemImage: "plus") { model.chooseFiles(for: script.id) }
                        .help("Add input files")
                } content: {
                    if inputs.isEmpty {
                        EmptyState(
                            symbol: "tray.and.arrow.down",
                            title: "No Input Files",
                            message: "Drag files here to use them the next time this script runs."
                        ) {
                            Button("Add Files…") { model.chooseFiles(for: script.id) }
                        }
                    } else {
                        GroupCard(inputs, isHighlighted: isSelected) { artifact in
                            switch artifact {
                            case .file(let url):
                                FileRow(url: url) {
                                    Button("Remove \(url.lastPathComponent)", systemImage: "xmark.circle.fill") {
                                        model.detach(url, from: script.id)
                                    }
                                }
                                .contextMenu {
                                    Button("Show in Finder") { reveal(url) }
                                    Button("Remove") { model.detach(url, from: script.id) }
                                }
                            case .form(let id):
                                let request = session?.questions[id]?.request
                                ArtifactRowLabel(
                                    icon: .form,
                                    title: request.map { $0.message.isEmpty ? "Form" : $0.message } ?? "Form",
                                    detail: "\(request?.fields.count ?? 0) fields"
                                ) {
                                    show(artifact)
                                }
                            case .output:
                                EmptyView()
                            }
                        }
                    }
                }

                .frame(maxWidth: .infinity, alignment: .topLeading)

                SidebarSection("Output") {
                    EmptyView()
                } content: {
                    if outputs.isEmpty {
                        if let session, !session.isRunning {
                            EmptyState(
                                symbol: "tray",
                                title: "No Output",
                                message: "This run didn’t produce any results or files."
                            ) {
                                EmptyView()
                            }
                        } else {
                            EmptyState(
                                symbol: "tray",
                                title: "No Output Yet",
                                message: "Results and files appear here when the script runs."
                            ) {
                                EmptyView()
                            }
                        }
                    } else {
                        GroupCard(outputs, isHighlighted: isSelected) { artifact in
                            switch artifact {
                            case .output(let id):
                                ArtifactRowLabel(
                                    icon: .output(session?.outputs[id]?.kind ?? .json),
                                    title: session?.outputName(id) ?? "Result",
                                    detail: session?.outputDetail(id) ?? ""
                                ) {
                                    show(artifact)
                                }
                            case .file(let url):
                                FileRow(url: url, name: session?.isNamed(url) == true ? session?.fileTitle(url) : nil) {
                                    Button("Show \(url.lastPathComponent) in Finder", systemImage: "folder") { reveal(url) }
                                }
                                // Two clicks open the file, one shows it in the preview.
                                .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                                .onTapGesture { show(artifact) }
                                .draggable(url)
                                .contextMenu {
                                    Button("Open") { NSWorkspace.shared.open(url) }
                                    Button("Show in Finder") { reveal(url) }
                                }
                            case .form:
                                EmptyView()
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(12)
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.receive(urls, for: script.id)
            return true
        } isTargeted: {
            isDropTargeted = $0
        }
        .overlay {
            if isDropTargeted {
                DropHighlight()
            }
        }
    }

    /// The row whose item the preview is showing.
    private func isSelected(_ artifact: ArtifactID) -> Bool {
        model.showsPreview && session?.shownArtifact == artifact
    }

    private func show(_ artifact: ArtifactID) {
        session?.pick(artifact)
        model.showsPreview = true
    }

    private func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Building blocks

/// A small heading with optional controls on its right, and what belongs under it.
private struct SidebarSection<Title: View, Accessory: View, Content: View>: View {
    @ViewBuilder let title: Title
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) where Title == Text {
        self.title = Text(title)
        self.accessory = accessory()
        self.content = content()
    }

    init(@ViewBuilder title: () -> Title, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title()
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                title
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                accessory
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)

            content
        }
    }
}

/// How the app's cards are drawn, so a form, a file list and a published
/// value all look like parts of one thing.
enum CardStyle {
    static let cornerRadius: CGFloat = 16
    /// Space between a card's edge and what is in it.
    static let inset: CGFloat = 16
    static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }
    /// The soft grey of a grouped list's cells on a white page.
    static var fill: Color { Color(nsColor: .quaternarySystemFill) }
}

/// A rounded group of rows, as in an iOS grouped list: generous corners, rows
/// tall enough to breathe, and hairlines between them that stop short of the
/// card's edges. No outline; the fill alone sets it apart.
struct GroupCard<Item: Hashable, Row: View>: View {
    let items: [Item]
    let isHighlighted: (Item) -> Bool
    @ViewBuilder let row: (Item) -> Row

    init(_ items: [Item], isHighlighted: @escaping (Item) -> Bool = { _ in false }, @ViewBuilder row: @escaping (Item) -> Row) {
        self.items = items
        self.isHighlighted = isHighlighted
        self.row = row
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element) { index, item in
                if index > 0 {
                    Rectangle()
                        .fill(.separator)
                        .frame(height: 0.5)
                        .padding(.horizontal, CardStyle.inset)
                }
                row(item)
                    .padding(.horizontal, CardStyle.inset)
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                    .background(isHighlighted(item) ? Color.accentColor.opacity(0.16) : .clear)
            }
        }
        .background(CardStyle.fill)
        .clipShape(CardStyle.shape)
    }
}

/// What a list says while it is empty: a symbol, a few plain words, and the
/// one thing to do about it, if there is one. No code, no jargon.
private struct EmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title)
                .imageScale(.large)
                .foregroundStyle(.tertiary)
                // A fixed height, so two empty lists side by side line up
                // whatever the shapes of their symbols.
                .frame(height: 38)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            actions
                .controlSize(.small)
                .padding(.top, 6)
        }
        .frame(maxWidth: 240)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }
}

// MARK: - Files

private struct FileRow<Accessory: View>: View {
    let url: URL
    /// The name the script gave the file, when it gave one.
    var name: String?
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
                .resizable()
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(name ?? url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            accessory
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .contentShape(Rectangle())
        .help(url.path(percentEncoded: false))
    }

    /// The size, after the file name when the row's title is something else.
    private var detail: String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)?.formatted(.byteCount(style: .file))
        return [name == nil ? nil : url.lastPathComponent, size].compactMap(\.self).joined(separator: ", ")
    }
}

/// A row for something that is not a file: the result or a submitted form.
/// A real button, so it also works from the keyboard and with VoiceOver.
private struct ArtifactRowLabel: View {
    let icon: ArtifactIcon
    let title: String
    let detail: String
    let show: () -> Void

    var body: some View {
        Button(action: show) {
            HStack(spacing: 8) {
                icon.image
                    .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .font(.callout)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show in the preview")
    }
}

/// Shown over an area while files are dragged above it.
struct DropHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .padding(6)
            .allowsHitTesting(false)
    }
}
