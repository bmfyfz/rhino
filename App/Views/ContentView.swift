import AppKit
import RhinoCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 360)
        } detail: {
            if let script = model.selectedScript {
                ScriptDetail(script: script)
            } else {
                ContentUnavailableView(
                    "No Script Selected",
                    systemImage: "curlybraces.square",
                    description: Text("Pick a script in the sidebar, or press ⌘N to create one.")
                )
            }
        }
        .overlay {
            if model.isPaletteVisible {
                Palette()
            }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(isPresented: $model.showsVersions) {
            VersionsSheet()
        }
        .sheet(isPresented: $model.showsPipelineBuilder) {
            PipelineSheet()
        }
        .sheet(item: $model.pendingApproval, onDismiss: { model.approvalSheetClosed() }) { approval in
            RunApprovalSheet(approval: approval)
        }
        // So a clicked notification can bring the window back after it was closed.
        .onAppear {
            model.openMainWindow = { openWindow(id: "main") }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshFromDisk()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            model.save()
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var folderName = ""

    var body: some View {
        @Bindable var model = model

        List(selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
            if query.allSatisfy(\.isWhitespace) {
                // Scripts at the top level first, then each folder with its own.
                ForEach(model.scripts.filter { $0.folder.isEmpty }) { row(for: $0) }
                // A folder is a row like any other, the size of the scripts
                // around it, that opens to show what is in it.
                ForEach(model.folders, id: \.self) { folder in
                    DisclosureGroup(isExpanded: Binding(
                        get: { !model.collapsedFolders.contains(folder) },
                        set: { if $0 { model.collapsedFolders.remove(folder) } else { model.collapsedFolders.insert(folder) } }
                    )) {
                        ForEach(model.scripts.filter { $0.folder == folder }) { row(for: $0) }
                    } label: {
                        FolderHeader(
                            path: folder,
                            count: model.scripts.count { $0.folder == folder },
                            isEmpty: !model.scripts.contains { $0.id.hasPrefix(folder + "/") }
                        )
                    }
                }
            } else {
                SearchResults(matches: model.search(query), query: query)
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search scripts")
        // Right-clicking the empty part of the list offers what the File menu does.
        .contextMenu {
            Button("New Script") { model.newScript() }
            Button("New Pipeline…") { model.showsPipelineBuilder = true }
                .disabled(model.scripts.isEmpty)
            Button("New Folder…") {
                model.folderPrompt = .init(purpose: .create(parent: "", moving: nil))
            }
        }
        .toolbar {
            ToolbarItem {
                Button("New Script", systemImage: "plus") { model.newScript() }
                    .help("New script (⌘N)")
            }
        }
        .alert(
            promptTitle,
            isPresented: Binding(get: { model.folderPrompt != nil }, set: { if !$0 { model.folderPrompt = nil } }),
            presenting: model.folderPrompt
        ) { prompt in
            TextField("Name", text: $folderName)
            Button(promptAction) { model.resolve(prompt, name: folderName) }
                .disabled(folderName.allSatisfy(\.isWhitespace))
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: model.folderPrompt?.id) {
            // A rename starts from the name the folder has; a new folder from nothing.
            if case .rename(let path)? = model.folderPrompt?.purpose {
                folderName = (path as NSString).lastPathComponent
            } else {
                folderName = ""
            }
        }
    }

    private var promptTitle: String {
        if case .rename? = model.folderPrompt?.purpose { return "Rename Folder" }
        return "New Folder"
    }

    private var promptAction: String {
        if case .rename? = model.folderPrompt?.purpose { return "Rename" }
        return "Create"
    }

    private func row(for script: Script) -> some View {
        ScriptRow(
            script: script,
            latestRun: model.history[script.id]?.first,
            schedule: model.schedules[script.id],
            isPaused: model.schedulesPaused
        )
        .tag(script.id)
        .contextMenu {
            Button("Run") { model.run(script.id) }
            Button("Show in Finder") { model.revealInFinder(script) }
            Menu("Move To") {
                Button("Top Level") { model.move(script.id, to: "") }
                    .disabled(script.folder.isEmpty)
                ForEach(model.folders, id: \.self) { folder in
                    Button(FolderHeader.title(of: folder)) { model.move(script.id, to: folder) }
                        .disabled(script.folder == folder)
                }
                Divider()
                Button("New Folder…") {
                    model.folderPrompt = .init(purpose: .create(parent: "", moving: script.id))
                }
            }
            Button("Browse Versions…") {
                model.select(script.id)
                model.save()
                model.showsVersions = true
            }
            Button("Clear Memory") { model.clearMemory(of: script.id) }
                .disabled(!model.remembersAnything(script.id))
            Divider()
            Button("Move to Trash", role: .destructive) { model.delete(script.id) }
        }
    }
}

/// A folder's heading in the sidebar. A folder inside another shows the
/// whole way to it, so the list stays flat and easy to scan.
private struct FolderHeader: View {
    @Environment(AppModel.self) private var model
    let path: String
    /// How many scripts are directly in it.
    let count: Int
    /// No script in it, or in any folder inside it.
    let isEmpty: Bool

    var body: some View {
        HStack(spacing: 8) {
            Label(Self.title(of: path), systemImage: "folder")
                .lineLimit(1)
            Spacer(minLength: 0)
            if count > 0 {
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        // As tall as a script's two lines would make it feel at home among them.
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu {
            Button("New Script Here") { model.newScript(in: path) }
            Button("New Folder Inside…") {
                model.folderPrompt = .init(purpose: .create(parent: path, moving: nil))
            }
            Button("Rename…") {
                model.folderPrompt = .init(purpose: .rename(path: path))
            }
            Divider()
            Button("Delete Folder", role: .destructive) { model.deleteFolder(path) }
                .disabled(!isEmpty)
        }
    }

    static func title(of path: String) -> String {
        path.split(separator: "/").joined(separator: " › ")
    }
}

/// What a search found: scripts by name and description, then lines of code.
/// Clicking a line opens the script at that line.
private struct SearchResults: View {
    @Environment(AppModel.self) private var model
    let matches: [ScriptSearch.Match]
    let query: String

    var body: some View {
        if matches.isEmpty {
            Text("No script matches “\(query.trimmingCharacters(in: .whitespaces))”.")
                .foregroundStyle(.secondary)
        }
        ForEach(matches) { match in
            Button {
                model.open(match)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.scripts.first { $0.id == match.scriptID }?.name ?? match.scriptID)
                            .lineLimit(1)
                        if case .code(let line) = match.place {
                            Text("line \(line)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    switch match.place {
                    case .name:
                        // The name is above; say where the script lives instead.
                        if let folder = model.scripts.first(where: { $0.id == match.scriptID })?.folder, !folder.isEmpty {
                            Text(FolderHeader.title(of: folder))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    case .description:
                        Text(match.text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    case .code:
                        Text(match.text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 2)
        }
    }
}

private struct ScriptRow: View {
    let script: Script
    let latestRun: RunListing?
    let schedule: AppModel.ScheduleInfo?
    let isPaused: Bool

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(script.name)
                    .lineLimit(1)
                if let summary = script.summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if latestRun?.outcome == .running {
                ProgressView().controlSize(.small)
            } else {
                // A failure nobody was watching has to be visible from the list.
                if latestRun?.outcome == .failed {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .help("The last run failed")
                }
                if let schedule {
                    if schedule.schedule == nil {
                        Image(systemName: "clock.badge.exclamationmark")
                            .foregroundStyle(.orange)
                            .help(schedule.problem ?? "The schedule could not be read")
                    } else {
                        Image(systemName: isPaused ? "pause.circle" : "clock")
                            .foregroundStyle(.secondary)
                            .help(isPaused ? "Scheduled (\(schedule.text)), paused" : "Runs \(schedule.text)")
                    }
                }
                if let shortcut = script.shortcut {
                    Text(shortcut.symbols)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail

private struct ScriptDetail: View {
    @Environment(AppModel.self) private var model
    let script: Script
    @State private var isDropTargeted = false
    /// Remembered, so hiding and showing a pane brings it back at the same size.
    @AppStorage("outputHeight") private var outputHeight = 280.0
    @AppStorage("previewWidth") private var previewWidth = 380.0
    /// How much of the editor's bottom the AI input covers.
    @State private var promptHeight: CGFloat = 0

    var body: some View {
        @Bindable var model = model
        let session = model.sessions[script.id]

        // Code and console on the left, the preview canvas beside them at
        // full height: the same arrangement as an editor with a live canvas.
        GeometryReader { geometry in
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    // The AI input floats over the bottom of the editor, with no
                    // band of its own; the code can still be scrolled clear of it.
                    CodeEditor(text: $model.source, isBeingWritten: model.aiActivity != nil, bottomInset: promptHeight, reveal: model.reveal, reindentRequests: model.reindentRequests)
                        .overlay(alignment: .bottom) {
                            PromptBar()
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { promptHeight = $0 }
                        }

                    if model.showsOutput {
                        // The editor always keeps at least 160 points.
                        let tallest = max(OutputResizeHandle.shortest, geometry.size.height - 160)
                        OutputResizeHandle(height: $outputHeight, tallest: tallest)
                        OutputPanel(script: script, session: session)
                            .frame(height: min(max(outputHeight, OutputResizeHandle.shortest), tallest))
                    }
                }

                if model.showsPreview {
                    // The code always keeps at least 360 points.
                    let widest = max(PreviewResizeHandle.narrowest, geometry.size.width - 360)
                    PreviewResizeHandle(width: $previewWidth, widest: widest)
                    PreviewPane(script: script, session: session)
                        .frame(width: min(max(previewWidth, PreviewResizeHandle.narrowest), widest))
                }
            }
        }
        // One line under the toolbar across both columns, so every pane has
        // a top edge.
        .overlay(alignment: .top) {
            Hairline(.horizontal)
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
        .sheet(item: Binding(get: { session?.pendingQuestions.first { $0.kind == .form } }, set: { _ in })) { prompt in
            if let session {
                FormSheet(session: session, prompt: prompt)
            }
        }
        .navigationTitle(script.name)
        .navigationSubtitle(model.isDirty ? "Edited" : "")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if session?.isRunning == true {
                    Button("Stop", systemImage: "stop.fill") { model.stopSelected() }
                        .help("Stop the run (⌘.)")
                } else {
                    Button("Run", systemImage: "play.fill") { model.runSelected() }
                        .help("Run this script (⌘R)")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Output", systemImage: "rectangle.bottomthird.inset.filled") { model.showsOutput.toggle() }
                    .help(model.showsOutput ? "Hide output (⇧⌘Y)" : "Show output (⇧⌘Y)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Preview", systemImage: "rectangle.righthalf.inset.filled") { model.showsPreview.toggle() }
                    .help(model.showsPreview ? "Hide preview (⌥⌘↩)" : "Show preview (⌥⌘↩)")
            }
        }
    }
}

/// A one-point line between two panes. Every separator in the window is this
/// same line, so where two of them meet they meet exactly.
struct Hairline: View {
    enum Direction {
        case horizontal, vertical
    }

    let direction: Direction

    init(_ direction: Direction) {
        self.direction = direction
    }

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: direction == .vertical ? 1 : nil, height: direction == .horizontal ? 1 : nil)
    }
}

/// The draggable edge between the code and the preview pane. It takes one
/// point of room, the line itself; the area that can be grabbed reaches a
/// few points to either side without pushing the panes apart.
private struct PreviewResizeHandle: View {
    static let narrowest = 260.0

    @Binding var width: Double
    let widest: Double
    @State private var widthAtDragStart: Double?

    var body: some View {
        Hairline(.vertical)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let start = widthAtDragStart ?? min(max(width, Self.narrowest), widest)
                                widthAtDragStart = start
                                // Dragging left makes the preview wider.
                                width = min(max(start - drag.translation.width, Self.narrowest), widest)
                            }
                            .onEnded { _ in widthAtDragStart = nil }
                    )
            }
            // Above its neighbours, so the grab area over them is reachable.
            .zIndex(1)
    }
}

/// The draggable edge between the editor and the output panel, built the
/// same way.
private struct OutputResizeHandle: View {
    static let shortest = 120.0

    @Binding var height: Double
    let tallest: Double
    @State private var heightAtDragStart: Double?

    var body: some View {
        Hairline(.horizontal)
            .overlay {
                Color.clear
                    .frame(height: 9)
                    .contentShape(Rectangle())
                    .pointerStyle(.rowResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let start = heightAtDragStart ?? min(max(height, Self.shortest), tallest)
                                heightAtDragStart = start
                                height = min(max(start - drag.translation.height, Self.shortest), tallest)
                            }
                            .onEnded { _ in heightAtDragStart = nil }
                    )
            }
            .zIndex(1)
    }
}

// MARK: - Editor

/// The code editor. SwiftUI's TextEditor rewrites quotes and dashes, which
/// breaks code, so this wraps NSTextView with every substitution turned off
/// and colors the JavaScript itself.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    /// The AI is writing into the editor: no typing, and keep the newest line in view.
    var isBeingWritten = false
    /// Space kept free under the last line, for something floating over the editor.
    var bottomInset: CGFloat = 0
    /// A line to scroll to and select, when a search result was opened.
    var reveal: AppModel.Reveal?
    /// Goes up each time the script should be re-indented.
    var reindentRequests = 0

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = CodeTextView(frame: .zero)
        context.coordinator.lastReindent = reindentRequests
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = SyntaxTheme.font
        textView.typingAttributes = SyntaxTheme.baseAttributes
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        // The numbers in the gutter sit close, so the code needs less room on its left.
        textView.textContainerInset = NSSize(width: 4, height: 10)
        // The gutter reads where each line is from the classic layout
        // manager; asking for it once makes the text view use it throughout.
        _ = textView.layoutManager

        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        SyntaxTheme.apply(to: textView)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets.bottom = bottomInset

        scrollView.verticalRulerView = LineNumberRuler(textView: textView, scrollView: scrollView)
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if scrollView.contentInsets.bottom != bottomInset {
            scrollView.contentInsets.bottom = bottomInset
        }
        textView.isEditable = !isBeingWritten
        if textView.string != text {
            // The text changed from outside the editor: another script was
            // selected, or the AI wrote some more.
            textView.string = text
            SyntaxTheme.apply(to: textView)
            textView.undoManager?.removeAllActions()
            (scrollView.verticalRulerView as? LineNumberRuler)?.textChanged()
            if isBeingWritten {
                textView.scrollToEndOfDocument(nil)
            } else {
                textView.scrollToBeginningOfDocument(nil)
            }
        }
        if reindentRequests != context.coordinator.lastReindent {
            context.coordinator.lastReindent = reindentRequests
            Self.reindent(textView)
        }
        if let reveal, reveal.request != context.coordinator.lastReveal {
            context.coordinator.lastReveal = reveal.request
            Self.show(line: reveal.line, in: textView)
        }
    }

    /// Tidies the indentation as one edit of the text view's own, so it can
    /// be undone, the view stays where it is scrolled, and the caret stays
    /// on its line.
    private static func reindent(_ textView: NSTextView) {
        let old = textView.string
        let tidy = Reindenter.reindent(old)
        guard tidy != old else { return }

        let content = old as NSString
        let caret = min(textView.selectedRange().location, content.length)
        let caretLine = content.substring(to: caret).reduce(into: 0) { count, character in
            if character == "\n" { count += 1 }
        }
        let whole = NSRange(location: 0, length: content.length)
        guard textView.shouldChangeText(in: whole, replacementString: tidy) else { return }
        textView.textStorage?.replaceCharacters(in: whole, with: tidy)
        textView.didChangeText()

        // Indenting never adds or removes a line, so the caret's line is still its line.
        let updated = tidy as NSString
        var start = 0
        var line = 0
        while line < caretLine, start < updated.length {
            start = NSMaxRange(updated.lineRange(for: NSRange(location: start, length: 0)))
            line += 1
        }
        let lineRange = updated.lineRange(for: NSRange(location: min(start, updated.length), length: 0))
        let text = updated.substring(with: lineRange)
        let indent = text.prefix { $0 == " " }.count
        textView.setSelectedRange(NSRange(location: lineRange.location + indent, length: 0))
    }

    /// Selects a line, counted from 1, and brings it into view.
    private static func show(line: Int, in textView: NSTextView) {
        let content = textView.string as NSString
        var start = 0
        var current = 1
        while current < line, start < content.length {
            start = NSMaxRange(content.lineRange(for: NSRange(location: start, length: 0)))
            current += 1
        }
        guard current == line, start <= content.length else { return }
        var range = content.lineRange(for: NSRange(location: start, length: 0))
        // Without the line break, so the selection ends where the text does.
        while range.length > 0, let last = UnicodeScalar(content.character(at: NSMaxRange(range) - 1)), CharacterSet.newlines.contains(last) {
            range.length -= 1
        }
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        /// The last request to show a line that was carried out.
        var lastReveal = 0
        /// The last request to re-indent that was carried out.
        var lastReindent = 0

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            SyntaxTheme.apply(to: textView)
            text.wrappedValue = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertTab(_:)):
                textView.insertText("  ", replacementRange: textView.selectedRange())
                return true
            case #selector(NSResponder.insertNewline(_:)):
                // Keep the current line's indentation, one level deeper after an opening bracket.
                let content = textView.string as NSString
                let caret = textView.selectedRange().location
                let line = content.substring(with: content.lineRange(for: NSRange(location: caret, length: 0)))
                var indent = String(line.prefix { $0 == " " || $0 == "\t" })
                let before = content.substring(to: caret).trimmingCharacters(in: .whitespaces)
                if let last = before.last, "{[(".contains(last) { indent += "  " }
                textView.insertText("\n" + indent, replacementRange: textView.selectedRange())
                return true
            default:
                return false
            }
        }
    }
}

/// Lets a file dropped on the editor reach the window's drop target instead of
/// being pasted into the code as a path.
private final class CodeTextView: NSTextView {
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes.filter { $0 != .fileURL && $0 != .URL && $0.rawValue != "NSFilenamesPboardType" }
    }
}
