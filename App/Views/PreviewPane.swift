import AppKit
import RhinoCore
import SwiftUI

/// The canvas beside the code: everything the run produced, one under the
/// other at full size, in the order it appeared. During a long run it keeps
/// the newest item in view, until the user picks one.
struct PreviewPane: View {
    @Environment(AppModel.self) private var model
    let script: Script
    let session: RunSession?
    /// The item that was just jumped to, marked for a moment so the eye finds it.
    @State private var flashed: ArtifactID?

    var body: some View {
        Group {
            if let session, !session.artifacts.isEmpty {
                column(for: session)
                    // A new run starts at the top.
                    .id(session.id)
            } else {
                Placeholder(session: session)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.background)
        // Scrolled items stop at the pane's top edge, like the code beside
        // them, instead of sliding up behind the toolbar.
        .clipped()
    }

    private func column(for session: RunSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(session.artifacts, id: \.self) { artifact in
                        VStack(alignment: .leading, spacing: 8) {
                            header(for: artifact, in: session)
                            ArtifactView(session: session, artifact: artifact)
                        }
                        .id(artifact)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            // Follow a long run: bring each new item into view as it is
            // published. A run that is over in a moment is read from the top.
            .onChange(of: session.artifacts.count) {
                guard session.followsNewest,
                      Date().timeIntervalSince(session.startedAt) > 1,
                      let newest = session.artifacts.last else { return }
                withAnimation { proxy.scrollTo(newest, anchor: .top) }
            }
            // A chip in the console or a row in the files list was clicked.
            .onChange(of: session.picks) {
                guard let picked = session.selectedArtifact else { return }
                withAnimation { proxy.scrollTo(picked, anchor: .top) }
                flash(picked)
            }
        }
    }

    private func header(for artifact: ArtifactID, in session: RunSession) -> some View {
        HStack(spacing: 8) {
            session.icon(of: artifact).image
                .frame(width: 16, height: 16)
            Text(session.title(of: artifact))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(flashed == artifact ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            actions(for: artifact, in: session)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        // In line with what is inside the card beneath, as a section's
        // heading sits over its rows.
        .padding(.horizontal, CardStyle.inset)
    }

    /// What can be done with an item, besides looking at it.
    @ViewBuilder private func actions(for artifact: ArtifactID, in session: RunSession) -> some View {
        switch artifact {
        case .output(let id):
            if let output = session.outputs[id], output.kind == .json {
                Button("Copy JSON", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output.json, forType: .string)
                }
                .help("Copy as JSON")
            }
        case .file(let url):
            Button("Open", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(url) }
                .help("Open \(url.lastPathComponent)")
            Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .help("Show in Finder")
        case .form:
            EmptyView()
        }
    }

    private func flash(_ artifact: ArtifactID) {
        withAnimation(.easeOut(duration: 0.15)) { flashed = artifact }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            if flashed == artifact {
                withAnimation(.easeIn(duration: 0.4)) { flashed = nil }
            }
        }
    }
}

/// What the preview says while there is nothing to show.
private struct Placeholder: View {
    let session: RunSession?

    var body: some View {
        Group {
            if session == nil {
                ContentUnavailableView(
                    "Nothing Run Yet",
                    systemImage: "play.rectangle",
                    description: Text("Run the script to see its results here.")
                )
            } else if session?.isRunning == true {
                ContentUnavailableView(
                    "Running…",
                    systemImage: "hourglass",
                    description: Text("Results appear here as the script produces them.")
                )
            } else {
                ContentUnavailableView(
                    "Nothing to Preview",
                    systemImage: "rectangle.dashed",
                    description: Text("This run didn’t produce anything to show.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - One artifact

/// One artifact in full: every field of a form, a published value, chart,
/// table, picture or note, or a look inside a file.
private struct ArtifactView: View {
    let session: RunSession
    let artifact: ArtifactID

    var body: some View {
        switch artifact {
        case .form(let id):
            if let question = session.questions[id], let values = question.formValues {
                let rows = ArtifactRow.rows(for: question.request, values: values)
                GroupCard(rows.map(\.id)) { index in
                    let row = rows[index]
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(row.label)
                        Spacer(minLength: 0)
                        Text(row.value)
                            .foregroundStyle(row.isPlaceholder ? .tertiary : .secondary)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                }
                .font(.body)
                // A form reads badly stretched across a wide pane.
                .frame(maxWidth: 520, alignment: .leading)
            }
        case .output(let id):
            if let output = session.outputs[id] {
                switch output.kind {
                case .json: JSONCard(json: output.json)
                case .image: ImageCard(json: output.json)
                case .chart: ChartCard(json: output.json)
                case .table: TableCard(json: output.json)
                case .text: TextCard(text: output.text ?? "")
                }
            }
        case .file(let url):
            FileDetail(url: url)
        }
    }
}

/// A result as the JSON it is: indented, monospaced and colored like code.
/// Lines never wrap, since wrapped JSON is hard to read; it scrolls sideways.
private struct JSONCard: View {
    let json: String

    var body: some View {
        ScrollView(.horizontal) {
            Text(SyntaxTheme.json(json))
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize()
        }
        .scrollIndicators(.never)
        .outputCard()
    }
}

/// A saved file: its name and size, and the start of its text.
private struct FileDetail: View {
    let url: URL
    @State private var preview: String?

    private enum Part: Hashable {
        case file, size, preview
    }

    var body: some View {
        GroupCard(parts) { part in
            switch part {
            case .file:
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("File")
                    Spacer(minLength: 0)
                    Text(url.lastPathComponent)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            case .size:
                HStack {
                    Text("Size")
                    Spacer(minLength: 0)
                    Text(size?.formatted(.byteCount(style: .file)) ?? "")
                        .foregroundStyle(.secondary)
                }
            case .preview:
                ScrollView(.horizontal) {
                    Text(preview ?? "")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize()
                }
                .scrollIndicators(.never)
            }
        }
        .font(.body)
        .task(id: url) {
            preview = Self.textPreview(of: url)
        }
    }

    private var size: Int? {
        try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }

    private var parts: [Part] {
        var parts: [Part] = [.file]
        if size != nil { parts.append(.size) }
        if preview != nil { parts.append(.preview) }
        return parts
    }

    /// The first lines of a text file, or nil when the file is not text.
    private static func textPreview(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard var data = try? handle.read(upToCount: 16 * 1024), !data.isEmpty else { return nil }

        // The cut may have landed inside a character; back off until it decodes.
        var text = String(data: data, encoding: .utf8)
        var trimmed = 0
        while text == nil, trimmed < 3, !data.isEmpty {
            data.removeLast()
            trimmed += 1
            text = String(data: data, encoding: .utf8)
        }
        guard let text else { return nil }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let limit = 60
        let shown = lines.count > limit ? lines.prefix(limit).joined(separator: "\n") + "\n…" : text
        return shown.trimmingCharacters(in: .newlines)
    }
}
