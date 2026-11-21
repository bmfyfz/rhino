import RhinoCore
import SwiftUI

/// ⌘P: find a script by name, open it with Return or run it with ⌘Return.
struct Palette: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var index = 0
    @FocusState private var isFocused: Bool

    var body: some View {
        let results = results

        ZStack(alignment: .top) {
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .onTapGesture(perform: close)

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search scripts", text: $query)
                        .textFieldStyle(.plain)
                        .focused($isFocused)
                        .onSubmit { open(results) }
                        .onKeyPress(.downArrow) { move(1, in: results) }
                        .onKeyPress(.upArrow) { move(-1, in: results) }
                }
                .font(.title3)
                .padding(14)

                Divider()

                if results.isEmpty {
                    Text("No script matches “\(query)”")
                        .foregroundStyle(.secondary)
                        .padding(24)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(results.enumerated()), id: \.element.id) { offset, script in
                                    PaletteRow(script: script, isSelected: offset == index)
                                        .id(script.id)
                                        .onTapGesture {
                                            index = offset
                                            open(results)
                                        }
                                }
                            }
                            .padding(6)
                        }
                        .frame(maxHeight: 320)
                        .onChange(of: index) {
                            if results.indices.contains(index) { proxy.scrollTo(results[index].id) }
                        }
                    }
                }

                Divider()

                HStack(spacing: 16) {
                    Text("↩ Open")
                    Text("⌘↩ Run")
                    Text("esc Close")
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .frame(width: 540)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
            .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
            .padding(.top, 70)
        }
        .background {
            // ⌘Return is a shortcut rather than a key press on the field, so it
            // works no matter what has focus inside the palette.
            Button("Run", action: { run(results) })
                .keyboardShortcut(.return, modifiers: .command)
                .hidden()
        }
        .onExitCommand(perform: close)
        .onChange(of: query) { index = 0 }
        .onAppear { isFocused = true }
    }

    /// Scripts whose name or id contains the query's letters in order, best matches first.
    private var results: [Script] {
        let needle = query.lowercased().filter { !$0.isWhitespace }
        guard !needle.isEmpty else { return model.scripts }

        func rank(_ script: Script) -> Int? {
            let name = script.name.lowercased()
            let id = script.id.lowercased()
            if name.hasPrefix(needle) || id.hasPrefix(needle) { return 0 }
            if name.contains(needle) || id.contains(needle) { return 1 }
            return isSubsequence(needle, of: name) || isSubsequence(needle, of: id) ? 2 : nil
        }
        return model.scripts
            .compactMap { script in rank(script).map { (script, $0) } }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    private func isSubsequence(_ needle: String, of text: String) -> Bool {
        var remaining = needle[...]
        for character in text where character == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return true }
        }
        return remaining.isEmpty
    }

    private func move(_ step: Int, in results: [Script]) -> KeyPress.Result {
        guard !results.isEmpty else { return .handled }
        index = (index + step + results.count) % results.count
        return .handled
    }

    private func open(_ results: [Script]) {
        guard results.indices.contains(index) else { return }
        model.select(results[index].id)
        close()
    }

    private func run(_ results: [Script]) {
        guard results.indices.contains(index) else { return }
        let id = results[index].id
        close()
        model.run(id)
    }

    private func close() {
        model.isPaletteVisible = false
    }
}

private struct PaletteRow: View {
    let script: Script
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "curlybraces")
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 1) {
                Text(script.name)
                Text(script.summary ?? "\(script.id).js")
                    .font(.caption)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let shortcut = script.shortcut {
                Text(shortcut.symbols)
                    .font(.callout)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(.secondary))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .background(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }
}
