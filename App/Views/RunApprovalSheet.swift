import RhinoCore
import SwiftUI

/// Asked before a script the AI wrote runs by itself: what it will reach for
/// outside itself, so the person can say yes knowing it. Asked again only
/// when a later change makes the script do something it did not do before.
struct RunApprovalSheet: View {
    @Environment(AppModel.self) private var model
    let approval: AppModel.RunApproval

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Run “\(approval.script.name)”?")
                    .font(.headline)
                Text(approval.isFirst
                    ? "The AI wrote this script. When it runs, it will:"
                    : "The AI changed this script. It will now also:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 20)

            Form {
                Section {
                    ForEach(approval.additions, id: \.key) { item in
                        Label {
                            Text(Self.description(of: item))
                                .textSelection(.enabled)
                        } icon: {
                            Image(systemName: Self.symbol(for: item))
                                .foregroundStyle(Self.isRisky(item) ? .orange : .secondary)
                        }
                    }
                } footer: {
                    Text("This is read from the code, so it is what the script says it does. You are asked again only if a change makes it do something new.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Not Now", role: .cancel) { model.answerApproval(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Run") { model.answerApproval(true) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460)
    }

    static func description(of item: ScriptFootprint.Item) -> String {
        switch item {
        case .host(let host): "Contact \(host)"
        case .anyHost: "Contact an address it works out while running"
        case .sends: "Send data out, not only fetch it"
        case .writes(let path): "Write the file \(path)"
        case .writesAnywhere: "Write a file in a place it works out while running"
        case .reads: "Read files from your disk"
        case .command(let command): "Run the command: \(command)"
        case .anyCommand: "Run a command it puts together while running"
        case .secret(let name): "Use your saved secret “\(name)”"
        case .ai: "Send text to your AI provider"
        case .notifies: "Show notifications"
        case .runs(let name): "Run the script “\(name)”"
        case .buildsCode: "Build code from text and run it, which hides what it does"
        }
    }

    private static func symbol(for item: ScriptFootprint.Item) -> String {
        switch item {
        case .host, .anyHost: "network"
        case .sends: "arrow.up.circle"
        case .writes, .writesAnywhere: "square.and.pencil"
        case .reads: "doc.text.magnifyingglass"
        case .command, .anyCommand: "terminal"
        case .secret: "key"
        case .ai: "sparkles"
        case .notifies: "bell"
        case .runs: "play.circle"
        case .buildsCode: "exclamationmark.triangle"
        }
    }

    /// The ones worth a second look: they can change things, or cannot be seen through.
    private static func isRisky(_ item: ScriptFootprint.Item) -> Bool {
        switch item {
        case .command, .anyCommand, .anyHost, .writesAnywhere, .buildsCode, .sends: true
        default: false
        }
    }
}
