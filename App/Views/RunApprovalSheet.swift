import RhinoCore
import SwiftUI

/// Asked before a script runs that the person has not run themselves: one
/// the AI just wrote, or one the command line tool wants to run. It says
/// what the script will reach for outside itself, so the person can say yes
/// knowing it. Asked again only when a later change makes the script do
/// something it did not do before.
struct RunApprovalSheet: View {
    @Environment(AppModel.self) private var model
    let approval: AppModel.RunApproval

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Run “\(approval.script.name)”?")
                    .font(.headline)
                Text(explanation)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 20)

            Form {
                Section {
                    ForEach(approval.additions, id: \.key) { item in
                        Label {
                            Text(item.summary)
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

    private var explanation: String {
        switch (approval.origin, approval.isFirst) {
        case (.ai, true): "The AI wrote this script. When it runs, it will:"
        case (.ai, false): "The AI changed this script. It will now also:"
        case (.commandLine, true): "The rhino command line tool wants to run this script. When it runs, it will:"
        case (.commandLine, false): "The rhino command line tool wants to run this script, which has changed. It will now also:"
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
