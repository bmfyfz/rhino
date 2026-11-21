import RhinoCore
import SwiftUI

/// The field floating over the bottom of the editor where the user says what
/// the script should do. The answer is written straight into the editor.
struct PromptBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @FocusState private var isFocused: Bool

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 8) {
            if let problem = model.aiProblem {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(problem.message)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if problem.needsSettings {
                        Button("Open Settings…") {
                            // Straight to where the key and the model are.
                            UserDefaults.standard.set(SettingsView.Pane.ai.rawValue, forKey: "settingsPane")
                            openSettings()
                        }
                    }
                    Button("Dismiss", systemImage: "xmark") { model.aiProblem = nil }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Dismiss")
                }
                .font(.callout)
                .controlSize(.small)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            Composer {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                    .composerRow()

                if let activity = model.aiActivity {
                    ProgressView()
                        .controlSize(.small)
                        .composerRow()
                    Text(Self.label(for: activity))
                        .foregroundStyle(.secondary)
                        .composerRow()
                    Spacer(minLength: 8)
                    ComposerActionButton(title: "Stop", symbol: "stop.fill") { model.stopAI() }
                } else {
                    TextField(placeholder, text: $model.aiPrompt, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .focused($isFocused)
                        .onSubmit { model.askAI() }
                        .composerRow()

                    if model.canUndoAI {
                        Button("Undo AI Change", systemImage: "arrow.uturn.backward") { model.undoAI() }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Put the script back the way it was before the AI changed it")
                            .composerRow()
                    }
                    ComposerActionButton(title: "Send (Return)") { model.askAI() }
                        .disabled(model.aiPrompt.allSatisfy(\.isWhitespace))
                }
            }
        }
        // Glass, so the code scrolling beneath stays visible but never
        // competes with what is being typed.
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .onChange(of: model.promptFocusRequests) { isFocused = true }
    }

    private static func label(for activity: AppModel.AIActivity) -> String {
        switch activity {
        case .thinking: "Thinking…"
        case .writing: "Writing the script…"
        case .asking: "Waiting for your OK to run it…"
        case .trying: "Trying it out…"
        case .fixing: "Fixing what went wrong…"
        }
    }

    private var placeholder: String {
        ScriptStore.isStarter(model.source)
            ? "Describe what this script should do…"
            : "Describe a change to this script…"
    }
}
