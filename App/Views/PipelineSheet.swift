import RhinoCore
import SwiftUI

/// Putting a pipeline together: a name, and the scripts to run in order.
/// What it makes is an ordinary script of one `pipeline(...)` call, which
/// can be edited, scheduled and versioned like any other.
struct PipelineSheet: View {
    private struct Step: Identifiable {
        let id = UUID()
        let script: Script
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var steps: [Step] = []

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("New Pipeline")
                    .font(.headline)
                Text("Scripts that run one after another")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .top], 20)

            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Weekly report"))
                }

                Section {
                    if steps.isEmpty {
                        Text("No steps yet")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        row(for: step, at: index)
                    }
                    Menu("Add Step") {
                        ForEach(model.scripts) { script in
                            Button(title(of: script)) { steps.append(Step(script: script)) }
                        }
                    }
                    .fixedSize()
                    .disabled(model.scripts.isEmpty)
                } header: {
                    Text("Steps")
                } footer: {
                    Text("Each step gets the result of the one before as its input.data. If a step fails, the pipeline stops there and says which one.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    model.newPipeline(named: name, steps: steps.map(\.script))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.allSatisfy(\.isWhitespace) || steps.isEmpty)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 500)
    }

    /// One step: its place in the order, the script, and buttons to move it
    /// up or down or take it out.
    private func row(for step: Step, at index: Int) -> some View {
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(step.script.name)
                    .lineLimit(1)
                if let summary = step.script.summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Group {
                Button("Move Up", systemImage: "arrow.up") { steps.swapAt(index, index - 1) }
                    .disabled(index == 0)
                Button("Move Down", systemImage: "arrow.down") { steps.swapAt(index, index + 1) }
                    .disabled(index == steps.count - 1)
                Button("Remove Step", systemImage: "minus.circle") { steps.remove(at: index) }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
    }

    /// A script's name, with its folder when it has one, so two of the same name can be told apart.
    private func title(of script: Script) -> String {
        script.folder.isEmpty ? script.name : "\(script.name) (\(script.folder))"
    }
}
