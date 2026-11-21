import Foundation

// What a script publishes besides plain JSON: pictures, charts, tables and
// notes. The script's side turns whatever it was given into a small, fixed
// JSON shape (see `output` in prelude.js); the types here read that shape so
// an app can draw it.

/// Where a published image comes from.
public enum ImageSource: Hashable, Sendable {
    case file(URL)
    case remote(URL)
    /// The image's bytes: from a `data:` URL, or SVG markup.
    case data(Data)

    public init?(json: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return nil }
        if let path = object["path"] as? String {
            self = .file(URL(filePath: path))
        } else if let text = object["url"] as? String, let url = URL(string: text) {
            self = .remote(url)
        } else if let svg = object["svg"] as? String {
            self = .data(Data(svg.utf8))
        } else if let text = object["data"] as? String,
                  let comma = text.firstIndex(of: ","),
                  text[..<comma].contains(";base64"),
                  let bytes = Data(base64Encoded: String(text[text.index(after: comma)...]), options: .ignoreUnknownCharacters) {
            self = .data(bytes)
        } else {
            return nil
        }
    }
}

/// A chart, as points ready to plot.
public struct ChartData: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case bar, line, area, point, pie
    }

    /// What the horizontal axis measures, which decides how it is drawn.
    public enum Axis: Sendable {
        case numbers, dates, categories
    }

    public struct Point: Identifiable, Hashable, Sendable {
        public let id: Int
        /// The x value as text; what a category axis shows.
        public let label: String
        /// The x value on a number axis.
        public let number: Double
        /// The x value on a date axis.
        public let date: Date
        public let y: Double
        /// Empty when the chart has a single series.
        public let series: String
    }

    public let kind: Kind
    public let title: String
    public let xLabel: String
    public let yLabel: String
    public let axis: Axis
    public let points: [Point]
    /// The series' names in the order they first appear. Empty for a single series.
    public let series: [String]

    public init?(json: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let rawPoints = object["points"] as? [[String: Any]] else { return nil }

        kind = Kind(rawValue: object["type"] as? String ?? "") ?? .bar
        title = object["title"] as? String ?? ""
        xLabel = object["xLabel"] as? String ?? ""
        yLabel = object["yLabel"] as? String ?? ""

        // A number axis needs every x to be a number, a date axis every x to
        // be a date; anything else is a list of categories.
        let xValues = rawPoints.map { $0["x"] }
        let numbers = xValues.map { ($0 as? NSNumber)?.doubleValue }
        let dates = xValues.map { ($0 as? String).flatMap { FormCoding.date(from: $0, kind: .dateTime) } }
        if !rawPoints.isEmpty, numbers.allSatisfy({ $0 != nil }) {
            axis = .numbers
        } else if !rawPoints.isEmpty, dates.allSatisfy({ $0 != nil }) {
            axis = .dates
        } else {
            axis = .categories
        }

        var names: [String] = []
        points = rawPoints.enumerated().compactMap { index, raw in
            guard let y = (raw["y"] as? NSNumber)?.doubleValue else { return nil }
            let series = raw["series"] as? String ?? ""
            if !series.isEmpty, !names.contains(series) { names.append(series) }
            let label = (raw["x"] as? String) ?? (raw["x"] as? NSNumber)?.stringValue ?? ""
            return Point(id: index, label: label, number: numbers[index] ?? 0, date: dates[index] ?? .distantPast, y: y, series: series)
        }
        series = names
    }
}

/// A table: named columns and rows of text.
public struct TableData: Hashable, Sendable {
    public let columns: [String]
    /// Columns that hold only numbers, which read best right-aligned.
    public let numericColumns: Set<Int>
    /// One array of cells per row, as long as `columns`.
    public let rows: [[String]]
    /// How many rows the script published; `rows` may hold only the first ones.
    public let totalRows: Int

    public init?(json: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let columns = object["columns"] as? [String],
              let rows = object["rows"] as? [[String]] else { return nil }
        self.columns = columns
        self.rows = rows
        totalRows = (object["total"] as? NSNumber)?.intValue ?? rows.count
        let flags = object["numeric"] as? [Bool] ?? []
        numericColumns = Set(flags.indices.filter { flags[$0] })
    }
}

extension OutputValue {
    /// The note of a `.text` output.
    public var text: String? {
        guard kind == .text else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed) as? String
    }
}
