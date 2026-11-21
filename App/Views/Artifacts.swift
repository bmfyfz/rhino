import AppKit
import RhinoCore
import SwiftUI

/// Something a run produced that is more than a line of text. The console
/// shows each as an icon chip; the preview pane shows them all in full, one
/// under the other.
enum ArtifactID: Hashable {
    /// A submitted form, by the id of its question.
    case form(UUID)
    /// A value the script published with `output.json()`.
    case output(UUID)
    case file(URL)
}

/// One row of a submitted form: a field and what was entered.
struct ArtifactRow: Identifiable {
    let id: Int
    let label: String
    let value: String
    /// Shown faintly: nothing was entered.
    var isPlaceholder = false

    static func rows(for request: PromptRequest, values: [String: FormValue]) -> [ArtifactRow] {
        request.fields.enumerated().map { index, field in
            let value = values[field.id] ?? .none
            let isEmpty = value == .none || value == .text("")
            return ArtifactRow(id: index, label: field.label, value: isEmpty ? "None" : field.describe(value), isPlaceholder: isEmpty)
        }
    }
}

/// What stands for an artifact wherever it is shown small.
enum ArtifactIcon {
    case form
    case output(OutputValue.Kind)
    case file(URL)

    @ViewBuilder var image: some View {
        switch self {
        case .form:
            Image(systemName: "list.bullet.rectangle.portrait.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.orange)
        case .output(let kind):
            Image(systemName: Self.symbol(for: kind))
                .resizable()
                .scaledToFit()
                .foregroundStyle(Self.color(for: kind))
        case .file(let url):
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
                .resizable()
                .scaledToFit()
        }
    }
}

extension ArtifactIcon {
    static func symbol(for kind: OutputValue.Kind) -> String {
        switch kind {
        case .json: "curlybraces.square.fill"
        case .image: "photo.fill"
        case .chart: "chart.bar.xaxis"
        case .table: "tablecells.fill"
        case .text: "doc.text.fill"
        }
    }

    static func color(for kind: OutputValue.Kind) -> Color {
        switch kind {
        case .json: .purple
        case .image: .green
        case .chart: .blue
        case .table: .teal
        case .text: .indigo
        }
    }
}

extension RunSession {
    /// What an artifact is called wherever it is listed.
    func title(of artifact: ArtifactID) -> String {
        switch artifact {
        case .form(let id):
            let name = questions[id]?.request.message ?? ""
            return name.isEmpty ? "Form" : name
        case .output(let id): return outputName(id)
        case .file(let url): return fileTitle(url)
        }
    }

    func icon(of artifact: ArtifactID) -> ArtifactIcon {
        switch artifact {
        case .form: .form
        case .output(let id): .output(outputs[id]?.kind ?? .json)
        case .file(let url): .file(url)
        }
    }
}

/// An artifact as a chip: its icon and name, like a file attached to a
/// message. Clicking it shows the artifact in the preview.
struct ArtifactChip: View {
    let icon: ArtifactIcon
    let title: String
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 6) {
                icon.image
                    .frame(width: 18, height: 18)
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.leading, 5)
            .padding(.trailing, 9)
            .padding(.vertical, 3)
            .background(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.16)) : AnyShapeStyle(Color(nsColor: .quaternarySystemFill)), in: shape)
            .overlay(shape.strokeBorder(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.7)) : AnyShapeStyle(.separator.opacity(0.5)), lineWidth: isSelected ? 1 : 0.5))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help("Show in the preview")
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
    }
}
