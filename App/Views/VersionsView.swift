import RhinoCore
import SwiftUI

/// A script's earlier versions: pick one to see what putting it back would
/// change, and put it back.
struct VersionsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selection: ScriptVersion.ID?

    private var selected: ScriptVersion? {
        model.scriptVersions.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                List(model.scriptVersions, selection: $selection) { version in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(version.title)
                            .lineLimit(2)
                        Text(version.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(version.id)
                }
                .frame(width: 270)

                Hairline(.vertical)

                if let selected {
                    VersionDiff(lines: LineDiff.lines(from: model.source, to: selected.source))
                } else {
                    ContentUnavailableView(
                        "No Version Selected",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Pick a version to see what putting it back would change.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            Hairline(.horizontal)

            HStack {
                Text(summary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Restore") {
                    if let selected { model.restore(selected) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil || selected?.source == model.source)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 900, height: 560)
        .onAppear {
            // The newest version is the script as it is; the one before it is the first worth looking at.
            selection = model.scriptVersions.first { $0.source != model.source }?.id ?? model.scriptVersions.first?.id
        }
    }

    private var summary: String {
        guard let selected else { return "" }
        let lines = LineDiff.lines(from: model.source, to: selected.source)
        let added = lines.filter { $0.kind == .added }.count
        let removed = lines.filter { $0.kind == .removed }.count
        if added == 0, removed == 0 { return "This is the script as it is now." }
        var parts: [String] = []
        if added > 0 { parts.append("\(added) \(added == 1 ? "line" : "lines") come back") }
        if removed > 0 { parts.append("\(removed) \(removed == 1 ? "line goes" : "lines go")") }
        return "Restoring: " + parts.joined(separator: ", ") + "."
    }
}

/// The version's code, with what differs from the script as it is now
/// marked: green for lines that would come back, red for lines that would go.
private struct VersionDiff: View {
    let lines: [LineDiff.Line]

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(spacing: 8) {
                        Text(marker(for: line.kind))
                            .foregroundStyle(.secondary)
                            .frame(width: 10)
                        Text(line.text.isEmpty ? " " : line.text)
                            .strikethrough(line.kind == .removed, color: .secondary)
                            .foregroundStyle(line.kind == .removed ? .secondary : .primary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 1.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(background(for: line.kind))
                }
            }
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .padding(.vertical, 8)
            .frame(minWidth: 620, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private func marker(for kind: LineDiff.Line.Kind) -> String {
        switch kind {
        case .same: " "
        case .added: "+"
        case .removed: "−"
        }
    }

    private func background(for kind: LineDiff.Line.Kind) -> Color {
        switch kind {
        case .same: .clear
        case .added: .green.opacity(0.16)
        case .removed: .red.opacity(0.13)
        }
    }
}

extension ScriptVersion {
    /// Why this version exists, in a few words for a list.
    var title: String {
        switch reason {
        case .original: "Original"
        case .edit: "Edited by hand"
        case .ai(let request): "AI: \(request)"
        case .repair: "AI repair after a failed run"
        case .undo: "AI change undone"
        case .restore(let date): "Restored version of \(date.formatted(date: .abbreviated, time: .shortened))"
        }
    }
}
