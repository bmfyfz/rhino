import AppKit
import Charts
import RhinoCore
import SwiftUI

// How the preview draws what a script published with output.image(),
// output.chart(), output.table() and output.text().

extension View {
    /// The rounded group every previewed item sits in.
    func outputCard(padding: CGFloat = CardStyle.inset) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CardStyle.fill)
            .clipShape(CardStyle.shape)
    }
}

/// What to say when a published item cannot be drawn.
private struct Unreadable: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.secondary)
            .outputCard()
    }
}

// MARK: - Image

struct ImageCard: View {
    let json: String

    var body: some View {
        switch ImageSource(json: json) {
        case .remote(let url):
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                case .failure:
                    Unreadable(text: "The picture at \(url.host() ?? "that address") could not be loaded.")
                default:
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 80)
                }
            }
            .outputCard(padding: 6)
        case .file(let url):
            picture(NSImage(contentsOf: url), missing: "\(url.lastPathComponent) is not a picture this Mac can show.")
        case .data(let data):
            picture(NSImage(data: data), missing: "This is not a picture this Mac can show.")
        case nil:
            Unreadable(text: "This picture could not be read.")
        }
    }

    @ViewBuilder private func picture(_ image: NSImage?, missing: String) -> some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                // Small pictures stay their own size instead of being blown up.
                .frame(maxWidth: image.size.width > 0 ? max(image.size.width, 120) : nil)
                .frame(maxWidth: .infinity)
                .outputCard(padding: 6)
                .onDrag { NSItemProvider(object: image) }
        } else {
            Unreadable(text: missing)
        }
    }
}

// MARK: - Chart

struct ChartCard: View {
    let json: String

    var body: some View {
        if let content = ChartData(json: json), !content.points.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !content.title.isEmpty {
                    Text(content.title)
                        .font(.headline)
                }
                plot(content)
                    .chartLegend(content.series.count > 1 || content.kind == .pie ? .visible : .hidden)
                    .frame(height: 300)
            }
            .outputCard()
        } else {
            Unreadable(text: "This chart could not be read.")
        }
    }

    @ViewBuilder private func plot(_ content: ChartData) -> some View {
        if content.kind == .pie {
            Chart(content.points) { point in
                SectorMark(angle: .value(content.yLabel, point.y), innerRadius: .ratio(0.55), angularInset: 1.5)
                    .cornerRadius(3)
                    .foregroundStyle(by: .value(content.xLabel, point.label))
            }
        } else {
            switch content.axis {
            case .numbers:
                Chart(content.points) { marks(for: $0, x: .value(content.xLabel, $0.number), in: content) }
            case .dates:
                Chart(content.points) { marks(for: $0, x: .value(content.xLabel, $0.date), in: content) }
            case .categories:
                Chart(content.points) { marks(for: $0, x: .value(content.xLabel, $0.label), in: content) }
            }
        }
    }

    /// One point drawn as the chart's kind of mark, whatever the x axis measures.
    @ChartContentBuilder
    private func marks<X: Plottable>(for point: ChartData.Point, x: PlottableValue<X>, in content: ChartData) -> some ChartContent {
        let y = PlottableValue.value(content.yLabel.isEmpty ? "Value" : content.yLabel, point.y)
        let series = PlottableValue.value("Series", point.series)
        switch content.kind {
        case .line:
            LineMark(x: x, y: y)
                .foregroundStyle(by: series)
                .symbol(by: series)
        case .area:
            AreaMark(x: x, y: y, stacking: .unstacked)
                .foregroundStyle(by: series)
                .opacity(content.series.count > 1 ? 0.5 : 0.8)
        case .point:
            PointMark(x: x, y: y)
                .foregroundStyle(by: series)
        default:
            BarMark(x: x, y: y)
                .foregroundStyle(by: series)
                .position(by: series)
        }
    }
}

// MARK: - Table

/// A published table as a native table: a header row, striped rows, columns
/// that can be resized, and scrolling in both directions when it is large.
struct TableCard: View {
    private struct Column: Identifiable {
        let id: Int
        let name: String
        let isNumeric: Bool
    }

    private struct Row: Identifiable {
        let id: Int
        let cells: [String]
    }

    /// Rows shown before the table scrolls inside its own frame.
    private static let visibleRows = 12

    let json: String

    var body: some View {
        if let table = TableData(json: json) {
            let columns = table.columns.enumerated().map { Column(id: $0.offset, name: $0.element, isNumeric: table.numericColumns.contains($0.offset)) }
            let rows = table.rows.enumerated().map { Row(id: $0.offset, cells: $0.element) }
            let shape = CardStyle.shape

            VStack(alignment: .leading, spacing: 6) {
                Table(rows) {
                    TableColumnForEach(columns) { column in
                        TableColumn(column.name) { (row: Row) in
                            Text(column.id < row.cells.count ? row.cells[column.id] : "")
                                .monospacedDigit()
                                .lineLimit(1)
                                // Numbers line up on the right, as in a spreadsheet.
                                .frame(maxWidth: .infinity, alignment: column.isNumeric ? .trailing : .leading)
                        }
                        // The heading sits over its numbers.
                        .alignment(column.isNumeric ? .trailing : .leading)
                    }
                }
                .tableStyle(.bordered(alternatesRowBackgrounds: true))
                // A table does not size itself to its rows, so it gets the
                // height of what it holds, up to a screenful.
                .frame(height: CGFloat(min(max(rows.count, 1), Self.visibleRows)) * 24 + 30)
                .clipShape(shape)
                .overlay(shape.strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))

                Text(caption(for: table))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        } else {
            Unreadable(text: "This table could not be read.")
        }
    }

    private func caption(for table: TableData) -> String {
        let columns = "\(table.columns.count) \(table.columns.count == 1 ? "column" : "columns")"
        if table.totalRows > table.rows.count {
            return "The first \(table.rows.count) of \(table.totalRows) rows, \(columns)"
        }
        return "\(table.totalRows) \(table.totalRows == 1 ? "row" : "rows"), \(columns)"
    }
}

// MARK: - Text

struct TextCard: View {
    let text: String

    var body: some View {
        Text(formatted)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .outputCard()
    }

    /// The note with its Markdown emphasis applied, line breaks kept as written.
    private var formatted: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
