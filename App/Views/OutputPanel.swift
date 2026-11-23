import AppKit
import RhinoCore
import SwiftUI
import UniformTypeIdentifiers

/// The panel under the editor, with two sides to switch between. Logs is
/// everything the latest run did, in the order it happened (log lines, HTTP
/// calls, questions), ending with the error if it failed; forms, saved files
/// and published items appear there as icon chips, and clicking one jumps to
/// it in the preview pane. Input/Output lists what went in and what came out.
struct OutputPanel: View {
    @Environment(AppModel.self) private var model
    let script: Script
    let session: RunSession?

    var body: some View {
        VStack(spacing: 0) {
            // A standard accessory bar: scope buttons choose what the panel
            // shows, and the run's state sits quietly at the other end. The
            // panel itself is hidden from the toolbar, as in other Mac apps.
            HStack(spacing: 4) {
                ScopeButton(title: "Logs", tab: .logs)
                ScopeButton(title: "Input & Output", tab: .files)
                Spacer(minLength: 12)
                if let schedule = model.schedules[script.id] {
                    ScheduleLabel(schedule: schedule, isPaused: model.schedulesPaused)
                        .padding(.trailing, 8)
                }
                if let watch = model.watches[script.id] {
                    WatchLabel(watch: watch, isPaused: model.schedulesPaused)
                        .padding(.trailing, 8)
                }
                let runs = model.history[script.id] ?? []
                RunStatus(session: session, isLatest: session?.id == runs.first?.id)
                if runs.count > 1 || (session == nil && !runs.isEmpty) {
                    RunHistoryMenu(script: script, runs: runs, shown: session)
                        .padding(.leading, 4)
                }
            }
            .controlSize(.small)
            .font(.subheadline)
            .padding(.horizontal, 8)
            .frame(height: 30)

            Hairline(.horizontal)

            if model.bottomTab == .files {
                ArtifactLists(script: script, session: session)
            } else if let session {
                // A new run starts with a fresh view: nothing expanded, scrolled to the top.
                OutputTimeline(session: session)
                    .id(session.id)
            } else {
                Text("Press ⌘R to run this script")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.background)
    }
}

/// One side of the panel, chosen the way a scope bar chooses: the selected
/// button is quietly filled, the others are plain text.
private struct ScopeButton: View {
    @Environment(AppModel.self) private var model
    let title: String
    let tab: AppModel.BottomTab

    var body: some View {
        Toggle(title, isOn: Binding(get: { model.bottomTab == tab }, set: { if $0 { model.bottomTab = tab } }))
            .toggleStyle(.button)
            .buttonStyle(.accessoryBar)
    }
}

/// The folder whose new files start the script, or why it is not watched.
private struct WatchLabel: View {
    let watch: AppModel.WatchInfo
    let isPaused: Bool

    var body: some View {
        Group {
            if let problem = watch.problem {
                Label {
                    Text("Folder not watched")
                } icon: {
                    Image(systemName: "folder.badge.questionmark").foregroundStyle(.orange)
                }
                .help(problem)
            } else {
                Label(isPaused ? "Paused: \(watch.text)" : "Watching \(watch.text)", systemImage: isPaused ? "pause.circle" : "folder")
                    .foregroundStyle(.secondary)
                    .help(isPaused
                        ? "Automatic runs are paused. Turn them back on in the Run menu."
                        : "Runs when a file arrives in \(watch.text), with that file as its input")
            }
        }
        .lineLimit(1)
    }
}

/// When the script runs by itself next, or why it will not.
private struct ScheduleLabel: View {
    let schedule: AppModel.ScheduleInfo
    let isPaused: Bool

    var body: some View {
        Group {
            if let problem = schedule.problem {
                Label {
                    Text("Schedule not understood")
                } icon: {
                    Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.orange)
                }
                .help(problem)
            } else if isPaused {
                Label("Paused: \(schedule.text)", systemImage: "pause.circle")
                    .foregroundStyle(.secondary)
                    .help("Schedules are paused. Turn them back on in the Run menu.")
            } else if let next = schedule.next {
                Label("\(schedule.text), next \(Self.describe(next))", systemImage: "clock")
                    .foregroundStyle(.secondary)
                    .help("Scheduled runs happen while Rhino is open, and use defaults for anything the script asks.")
            }
        }
        .lineLimit(1)
    }

    /// "15:00" for today, "Mon 09:00" for another day.
    static func describe(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

/// The script's last runs, to look at one that is no longer on screen.
private struct RunHistoryMenu: View {
    @Environment(AppModel.self) private var model
    let script: Script
    let runs: [RunListing]
    let shown: RunSession?
    @State private var confirmsClearing = false

    var body: some View {
        Menu {
            // Grouped by day, newest first, the way a browser lists its history.
            ForEach(days, id: \.day) { group in
                Section(heading(for: group.day)) {
                    ForEach(group.runs) { run in
                        Button {
                            model.show(run, of: script.id)
                        } label: {
                            Label(title(of: run), systemImage: run.id == shown?.id ? "checkmark" : icon(of: run))
                        }
                    }
                }
            }
            Divider()
            Button("Clear History…") { confirmsClearing = true }
        } label: {
            Label("Earlier Runs", systemImage: "clock.arrow.circlepath")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Earlier runs")
        .confirmationDialog("Clear the history of “\(script.name)”?", isPresented: $confirmsClearing) {
            Button("Clear History", role: .destructive) { model.clearHistory(of: script.id) }
        } message: {
            Text("Its earlier runs and their logs will be forgotten. Files the runs saved are kept.")
        }
    }

    private var days: [(day: Date, runs: [RunListing])] {
        let calendar = Calendar.current
        return Dictionary(grouping: runs) { calendar.startOfDay(for: $0.startedAt) }
            .map { (day: $0.key, runs: $0.value) }
            .sorted { $0.day > $1.day }
    }

    private func heading(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    private func title(of run: RunListing) -> String {
        let time = run.startedAt.formatted(date: .omitted, time: .standard)
        let outcome = switch run.outcome {
        case .running: "running"
        case .finished: "finished"
        case .failed: "failed"
        }
        return "\(time), \(run.isScheduled ? "automatic, " : "")\(outcome)"
    }

    private func icon(of run: RunListing) -> String {
        switch run.outcome {
        case .running: "circle.dotted"
        case .finished: "checkmark.circle"
        case .failed: "xmark.octagon"
        }
    }
}

/// How the run on show went. The symbol carries the state in colour; the
/// words stay in the label colours, so the bar reads calmly.
private struct RunStatus: View {
    let session: RunSession?
    /// Whether the run on show is the script's most recent one.
    let isLatest: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let session, let when = when(session) {
                Text(when)
                    .foregroundStyle(.tertiary)
            }
            status
        }
        .lineLimit(1)
    }

    /// When the run started, wherever that is not obvious: a scheduled run,
    /// an earlier run picked from the history, or one from another day.
    private func when(_ session: RunSession) -> String? {
        let isToday = Calendar.current.isDateInToday(session.startedAt)
        guard session.trigger != .manual || !isLatest || !isToday else { return nil }
        let time = isToday
            ? session.startedAt.formatted(date: .omitted, time: .shortened)
            : session.startedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        return switch session.trigger {
        case .manual: time
        case .schedule: "Scheduled, \(time)"
        case .folder: "New file, \(time)"
        case .shortcut: "Shortcut, \(time)"
        case .commandLine: "Command line, \(time)"
        }
    }

    @ViewBuilder private var status: some View {
        if let session {
            if let summary = session.summary {
                if summary.error == nil {
                    state("Finished in \(summary.duration.formattedDuration)", symbol: "checkmark.circle.fill", color: .green)
                        .foregroundStyle(.secondary)
                } else {
                    state("Failed after \(summary.duration.formattedDuration)", symbol: "xmark.octagon.fill", color: .red)
                }
            } else if session.pendingQuestions.isEmpty {
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Running…")
                        .foregroundStyle(.secondary)
                }
            } else {
                state("Waiting for your answer", symbol: "questionmark.circle.fill", color: .orange)
            }
        } else {
            Text("Not run yet")
                .foregroundStyle(.tertiary)
        }
    }

    private func state(_ text: String, symbol: String, color: Color) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(color)
        }
    }
}

// MARK: - Timeline

private struct OutputTimeline: View {
    @Environment(AppModel.self) private var model
    let session: RunSession
    /// HTTP calls shown with their details.
    @State private var expanded: Set<UUID> = []
    private let bottomID = "bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(session.entries) { entry in
                        row(for: entry)
                    }
                    if let summary = session.summary {
                        Outcome(session: session, summary: summary)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            // Follow the run: keep the newest line, and then the result, in view.
            .onChange(of: session.entries.count) { proxy.scrollTo(bottomID, anchor: .bottom) }
            .onChange(of: session.isRunning) { proxy.scrollTo(bottomID, anchor: .bottom) }
        }
    }

    @ViewBuilder private func row(for entry: RunSession.Entry) -> some View {
        switch entry {
        case .log(let log):
            Line(date: log.date, script: scriptName(log.runID)) {
                Text(log.message)
                    .foregroundStyle(color(for: log.level))
                    .textSelection(.enabled)
            }
        case .span(let id):
            if let span = session.spans[id] {
                SpanRow(span: span, script: scriptName(span.runID), isExpanded: expanded.contains(id)) {
                    expanded.formSymmetricDifference([id])
                }
            }
        case .file(_, let runID, let url, let date):
            Line(date: date, script: scriptName(runID)) {
                Text("Saved")
                    .foregroundStyle(.secondary)
                ArtifactChip(icon: .file(url), title: session.fileTitle(url), isSelected: isShown(.file(url))) {
                    select(.file(url))
                }
                .draggable(url)
            }
        case .notification(let notification):
            Line(date: notification.date, script: scriptName(notification.runID)) {
                Image(systemName: "bell.fill")
                    .foregroundStyle(.secondary)
                Text(notification.title)
                    .fontWeight(.medium)
                    .textSelection(.enabled)
                if !notification.message.isEmpty {
                    Text(notification.message)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .help("Sent as a notification")
        case .output(let id):
            if let output = session.outputs[id] {
                Line(date: output.date, script: scriptName(output.runID)) {
                    ArtifactChip(icon: .output(output.kind), title: session.outputName(id), isSelected: isShown(.output(id))) {
                        select(.output(id))
                    }
                }
            }
        case .question(let id):
            if let question = session.questions[id] {
                if question.isPending, question.request.kind == .form {
                    Line(date: question.askedAt, script: scriptName(question.request.runID)) {
                        Image(systemName: "list.bullet.rectangle")
                            .foregroundStyle(.orange)
                        Text("Waiting for the form to be filled in")
                            .foregroundStyle(.secondary)
                    }
                } else if question.isPending {
                    PromptCard(session: session, prompt: question.request, scriptName: scriptName(question.request.runID))
                } else if question.formValues != nil {
                    Line(date: question.askedAt, script: scriptName(question.request.runID)) {
                        ArtifactChip(
                            icon: .form,
                            title: question.request.message.isEmpty ? "Form" : question.request.message,
                            isSelected: isShown(.form(id))
                        ) {
                            select(.form(id))
                        }
                    }
                } else {
                    Line(date: question.askedAt, script: scriptName(question.request.runID)) {
                        Image(systemName: question.request.kind == .form ? "list.bullet.rectangle" : "questionmark.bubble")
                            .foregroundStyle(.secondary)
                        if !question.request.message.isEmpty {
                            Text(question.request.message)
                                .foregroundStyle(.secondary)
                        }
                        Text(question.answer ?? "Cancelled")
                            .fontWeight(.medium)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    /// Whether this is the current item: the newest, or the one last picked.
    private func isShown(_ artifact: ArtifactID) -> Bool {
        model.showsPreview && session.shownArtifact == artifact
    }

    /// Jumps to an artifact in the preview, opening the pane if needed.
    private func select(_ artifact: ArtifactID) {
        session.pick(artifact)
        model.showsPreview = true
    }

    /// Only worth showing when more than one script took part in the run.
    private func scriptName(_ runID: String) -> String? {
        session.isChained ? session.scriptName(for: runID) : nil
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .error: .red
        case .warn: .orange
        case .debug: .secondary
        case .info: .primary
        }
    }
}

/// One timestamped line of output.
private struct Line<Content: View>: View {
    let date: Date
    let script: String?
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits).secondFraction(.fractional(3))))
                .foregroundStyle(.tertiary)
            if let script {
                Text(script)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .font(.system(.callout, design: .monospaced))
    }
}

// MARK: - HTTP calls

private struct SpanRow: View {
    let span: HTTPSpan
    let script: String?
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                Line(date: span.startedAt, script: script) {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(span.method)
                        .fontWeight(.semibold)
                    Text(statusText)
                        .foregroundStyle(color)
                    Text(span.url)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(span.duration?.formattedDuration ?? "…")
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                SpanDetail(span: span)
            }
        }
    }

    private var statusText: String {
        if let status = span.status { return "\(status)" }
        return span.error == nil ? "…" : "ERR"
    }

    private var color: Color {
        guard let status = span.status else { return span.error == nil ? .secondary : .red }
        switch status {
        case 200..<300: return .green
        case 300..<400: return .blue
        case 400..<500: return .orange
        default: return .red
        }
    }
}

private struct SpanDetail: View {
    let span: HTTPSpan

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = span.error {
                Text(error).foregroundStyle(.red)
            }
            section("Request headers", headers: span.requestHeaders)
            section("Request body", body: span.requestBody)
            section("Response headers", headers: span.responseHeaders)
            section("Response body (\(span.responseSize.formatted(.byteCount(style: .file))))", body: span.responseBody)
        }
        .font(.system(.callout, design: .monospaced))
        .textSelection(.enabled)
        .padding(.leading, 20)
        .padding(.bottom, 4)
    }

    @ViewBuilder private func section(_ title: String, headers: [String: String]) -> some View {
        if !headers.isEmpty {
            section(title, body: headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
        }
    }

    @ViewBuilder private func section(_ title: String, body: String?) -> some View {
        if let body, !body.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

// MARK: - Questions

/// A single question a script asked with `input.ask()` or `input.file()`,
/// answered in place so the code and the output so far stay visible.
private struct PromptCard: View {
    let session: RunSession
    let prompt: PromptRequest
    let scriptName: String?
    @State private var text = ""
    @State private var choice = ""
    @State private var yes = true
    @FocusState private var isFocused: Bool

    var body: some View {
        // The question, and under it the same bar the AI prompt uses: the
        // answer in a round field with a send button at its end, and a
        // round button before it that calls the question off.
        VStack(alignment: .leading, spacing: 8) {
            question
            HStack(spacing: 8) {
                ComposerCancelButton(title: "Cancel (Esc)", shortcut: .cancelAction) {
                    session.answer(prompt, with: .cancelled)
                }
                if typesAnswer {
                    Composer { answerControls }
                        .frame(maxWidth: 520)
                } else {
                    // Nothing to type, so the bar is only as wide as its controls.
                    Composer { answerControls }
                        .fixedSize()
                }
            }
        }
        .padding(.vertical, 6)
        .onAppear {
            text = prompt.defaultText ?? ""
            choice = prompt.defaultText.flatMap { prompt.options.contains($0) ? $0 : nil } ?? prompt.options.first ?? ""
            yes = prompt.defaultText != "false"
            isFocused = true
        }
    }

    /// The question is whether a script may use a secret that is already saved.
    private var asksPermission: Bool {
        prompt.kind == .confirm && prompt.secretName != nil
    }

    private var typesAnswer: Bool {
        switch prompt.kind {
        case .text, .number, .secret: true
        default: false
        }
    }

    private var question: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: asksPermission ? "key.fill" : "questionmark.bubble.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(prompt.message)
                    .fontWeight(.medium)
                if let scriptName {
                    Text("Asked by \(scriptName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if asksPermission {
                    Text("This script has not used this secret before. Allow it only if you trust what the script does with it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if prompt.secretName != nil {
                    Text("Saved in your Keychain, so you are only asked once.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var answerControls: some View {
        switch prompt.kind {
        case .text, .number:
            TextField(prompt.placeholder.isEmpty ? "Answer" : prompt.placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit(submitText)
                .composerRow()
            ComposerActionButton(title: "Answer (Return)", action: submitText)
                .disabled(prompt.kind == .number && number == nil)
        case .secret:
            Image(systemName: "key.fill")
                .foregroundStyle(.secondary)
                .composerRow()
            SecureField(prompt.placeholder.isEmpty ? "Answer" : prompt.placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit(submitText)
                .composerRow()
            // A secret asked for by name is kept, so the button says so.
            ComposerActionButton(title: prompt.secretName == nil ? "Answer (Return)" : "Save (Return)", action: submitText)
                .disabled(prompt.secretName != nil && text.isEmpty)
        case .confirm:
            Picker("Answer", selection: $yes) {
                Text(asksPermission ? "Don’t Allow" : "No").tag(false)
                Text(asksPermission ? "Allow" : "Yes").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .composerRow()
            ComposerActionButton(title: "Answer (Return)", shortcut: .defaultAction) {
                session.answer(prompt, with: .bool(yes))
            }
        case .choice:
            Picker("Choice", selection: $choice) {
                ForEach(prompt.options, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
            .buttonStyle(.borderless)
            .labelsHidden()
            .fixedSize()
            .composerRow()
            ComposerActionButton(title: "Answer (Return)", shortcut: .defaultAction) {
                session.answer(prompt, with: .text(choice))
            }
        case .file:
            Text("Drop a file on the window, or choose one")
                .foregroundStyle(.secondary)
                .composerRow()
            ComposerActionButton(title: "Choose File…", symbol: "folder.fill", shortcut: .defaultAction) {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = false
                panel.message = prompt.message
                // For a file question the options are the extensions the script accepts.
                let types = prompt.options.compactMap { UTType(filenameExtension: $0) }
                if !types.isEmpty { panel.allowedContentTypes = types }
                if panel.runModal() == .OK, let url = panel.url {
                    session.answer(prompt, with: .file(url))
                }
            }
        case .form:
            // Forms are shown as a sheet; see FormSheet.
            EmptyView()
        }
    }

    private var number: Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacing(",", with: "."))
    }

    private func submitText() {
        if prompt.kind == .number {
            if let number { session.answer(prompt, with: .number(number)) }
        } else {
            session.answer(prompt, with: .text(text))
        }
    }
}

// MARK: - Result

/// The last thing in the output when there is something to say about how the
/// run ended: why it failed, or that it produced nothing at all.
private struct Outcome: View {
    @Environment(AppModel.self) private var model
    let session: RunSession
    let summary: RunSummary

    var body: some View {
        if let error = summary.error {
            VStack(alignment: .leading, spacing: 8) {
                if !session.entries.isEmpty {
                    Divider().padding(.vertical, 4)
                }
                Text("\(error.name): \(error.message)")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                if let script = error.script {
                    Text(error.line.map { "\(script).js, line \($0)" } ?? "\(script).js")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button("Fix with AI", systemImage: "sparkles") { model.fixWithAI() }
                    .disabled(model.aiActivity != nil)
                    .help("Send the error and the script to the AI and let it repair the script")
            }
        } else if session.entries.isEmpty {
            Text("The run finished without logging or producing anything.")
                .foregroundStyle(.secondary)
        }
    }
}
