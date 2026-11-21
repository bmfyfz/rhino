import RhinoCore
import SwiftUI
import UserNotifications

/// Closing the window must not quit the app: scheduled scripts only run
/// while it is open.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// A failed run's notification was clicked: show that run.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let script = info["script"] as? String
        let run = (info["run"] as? String).flatMap { UUID(uuidString: $0) }
        await MainActor.run {
            AppModel.shared.openRun(run, of: script)
        }
    }

    /// A failure is worth a banner even while the app is in front: the run
    /// that failed may not be the script on screen.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}

@main
struct RhinoApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Rhino", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 540)
        }
        .defaultSize(width: 1280, height: 780)
        .commands {
            AppCommands(model: model)
        }

        Settings {
            SettingsView()
                .environment(model)
        }

        // Only there when something is scheduled: it shows the app is still
        // running, and what it will do next, once the window is closed.
        MenuBarExtra("Rhino", systemImage: "gearshape.2", isInserted: Binding(get: { !model.schedules.isEmpty || !model.watches.isEmpty }, set: { _ in })) {
            MenuBarContent()
                .environment(model)
        }

        Window("API Reference", id: "api") {
            APIReferenceView()
        }
        .defaultSize(width: 720, height: 760)
    }
}

struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Script") { model.newScript() }
                .keyboardShortcut("n")
            Button("New Pipeline…") { model.showsPipelineBuilder = true }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(model.scripts.isEmpty)
            Button("New Folder…") { model.folderPrompt = .init(purpose: .create(parent: "", moving: nil)) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Open Quickly…") { model.isPaletteVisible = true }
                .keyboardShortcut("p")
            Button("Ask AI…") { model.focusPrompt() }
                .keyboardShortcut("k")
                .disabled(model.selectedID == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { model.save() }
                .keyboardShortcut("s")
                .disabled(!model.isDirty)
            // As in document apps: the latest versions here, all of them in the browser.
            Menu("Revert To") {
                ForEach(model.scriptVersions.prefix(8)) { version in
                    Button("\(version.date.formatted(date: .abbreviated, time: .shortened)), \(version.title)") {
                        model.restore(version)
                    }
                    .disabled(version.source == model.source)
                }
                if !model.scriptVersions.isEmpty { Divider() }
                Button("Browse All Versions…") {
                    model.save()
                    model.showsVersions = true
                }
            }
            .disabled(model.selectedID == nil || model.scriptVersions.isEmpty)
        }
        CommandGroup(after: .textEditing) {
            // Control-I, as in Xcode.
            Button("Re-Indent") { model.reindent() }
                .keyboardShortcut("i", modifiers: .control)
                .disabled(model.selectedID == nil || model.aiActivity != nil)
        }
        CommandGroup(after: .sidebar) {
            Button(model.showsOutput ? "Hide Output" : "Show Output") { model.showsOutput.toggle() }
                .keyboardShortcut("y", modifiers: [.command, .shift])
            Button(model.showsPreview ? "Hide Preview" : "Show Preview") { model.showsPreview.toggle() }
                .keyboardShortcut(.return, modifiers: [.command, .option])
        }
        CommandMenu("Run") {
            Button("Run Script") { model.runSelected() }
                .keyboardShortcut("r")
                .disabled(model.selectedID == nil)
            Button("Stop") { model.stopSelected() }
                .keyboardShortcut(".")
            Divider()
            Toggle("Pause Schedules", isOn: Binding(get: { model.schedulesPaused }, set: { model.schedulesPaused = $0 }))
            Divider()
            // Every script is listed here, which is also what makes its
            // `// @key` shortcut work from anywhere in the app.
            ForEach(model.scripts) { script in
                Button("Run “\(script.name)”") { model.run(script.id) }
                    .keyboardShortcut(script.shortcut?.keyboardShortcut)
            }
        }
        CommandGroup(replacing: .help) {
            Button("Script API Reference") { openWindow(id: "api") }
        }
    }
}

/// The menu behind the menu bar icon: what is scheduled and when it runs next.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let scheduled = model.scripts.filter { model.schedules[$0.id]?.schedule != nil }

        if scheduled.isEmpty {
            Text("No script has a schedule that can be read")
        }
        ForEach(scheduled) { script in
            Button(title(of: script)) {
                model.select(script.id)
                open()
            }
        }
        Divider()
        Toggle("Pause Schedules", isOn: Binding(get: { model.schedulesPaused }, set: { model.schedulesPaused = $0 }))
        Divider()
        Button("Open Rhino", action: open)
        Button("Quit Rhino") { NSApplication.shared.terminate(nil) }
    }

    private func title(of script: Script) -> String {
        guard !model.schedulesPaused, let next = model.schedules[script.id]?.next else { return script.name }
        let time = Calendar.current.isDateInToday(next)
            ? next.formatted(date: .omitted, time: .shortened)
            : next.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        return "\(script.name), next \(time)"
    }

    private func open() {
        openWindow(id: "main")
        NSApplication.shared.activate()
    }
}

/// The same declarations an AI gets when it writes a script.
struct APIReferenceView: View {
    var body: some View {
        ScrollView {
            Text(API.typeDefinitions)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
    }
}
