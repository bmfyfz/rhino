import Foundation

/// One field of a form a script asked for with `input.form()`.
public struct FormField: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case text, multiline, number, secret, toggle, select, date
        case dateTime = "datetime"
        case time, file
    }

    /// The key the value is returned under.
    public let id: String
    public let label: String
    public let kind: Kind
    public let placeholder: String
    /// A short explanation shown under the label.
    public let help: String
    public let isRequired: Bool
    /// Choices for `.select`; allowed extensions (may be empty) for `.file`.
    public let options: [String]
    /// Bounds for `.number`.
    public let minimum: Double?
    public let maximum: Double?
    /// What the field starts with. Date fields always start with a date.
    public let defaultValue: FormValue

    /// Whether `value` is acceptable for this field.
    public func accepts(_ value: FormValue) -> Bool {
        switch value {
        case .none:
            return !isRequired
        case .text(let text):
            return !isRequired || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .number(let number):
            return (minimum.map { number >= $0 } ?? true) && (maximum.map { number <= $0 } ?? true)
        case .option(let index):
            return options.indices.contains(index)
        case .bool, .date, .file:
            return true
        }
    }
}

public enum FormValue: Hashable, Codable, Sendable {
    /// Nothing entered or chosen.
    case none
    case text(String)
    case number(Double)
    case bool(Bool)
    case date(Date)
    /// Index into the field's options.
    case option(Int)
    case file(URL)
}

extension FormField {
    /// Builds a field from the description the JavaScript side sends.
    init?(json: [String: Any], now: Date = Date()) {
        guard let key = json["key"] as? String,
              let kind = Kind(rawValue: json["type"] as? String ?? "") else { return nil }
        let options = (json["options"] as? [Any] ?? []).map { "\($0)" }
        let isRequired = json["required"] as? Bool ?? false
        let fallback = json["default"]

        let defaultValue: FormValue
        switch kind {
        case .text, .multiline, .secret:
            if let text = fallback as? String {
                defaultValue = .text(text)
            } else if let number = fallback as? NSNumber {
                defaultValue = .text(number.stringValue)
            } else {
                defaultValue = .text("")
            }
        case .number:
            defaultValue = (fallback as? NSNumber).map { .number($0.doubleValue) } ?? .none
        case .toggle:
            defaultValue = .bool(fallback as? Bool ?? false)
        case .select:
            if let index = (fallback as? NSNumber)?.intValue, options.indices.contains(index) {
                defaultValue = .option(index)
            } else {
                // A required choice starts on the first option; an optional one starts empty.
                defaultValue = isRequired && !options.isEmpty ? .option(0) : .none
            }
        case .date, .dateTime, .time:
            defaultValue = .date((fallback as? String).flatMap { FormCoding.date(from: $0, kind: kind, now: now) } ?? now)
        case .file:
            defaultValue = .none
        }

        self.init(
            id: key,
            label: json["label"] as? String ?? key,
            kind: kind,
            placeholder: json["placeholder"] as? String ?? "",
            help: json["help"] as? String ?? "",
            isRequired: isRequired,
            options: options,
            minimum: (json["min"] as? NSNumber)?.doubleValue,
            maximum: (json["max"] as? NSNumber)?.doubleValue,
            defaultValue: defaultValue
        )
    }
}

/// How form values travel between Swift and a script.
enum FormCoding {
    /// The object handed back to JavaScript, keyed by field. Dates become
    /// strings: "2026-03-05" for a date, "14:30" for a time, and ISO 8601 with
    /// the local UTC offset for a date and time. A choice becomes its index,
    /// which the JavaScript side maps back to the option's own value.
    static func encode(_ values: [String: FormValue], fields: [FormField]) -> [String: Any] {
        var result: [String: Any] = [:]
        for field in fields {
            switch values[field.id] ?? .none {
            case .none: result[field.id] = NSNull()
            case .text(let text): result[field.id] = text
            case .number(let number): result[field.id] = number
            case .bool(let flag): result[field.id] = flag
            case .option(let index): result[field.id] = index
            case .date(let date): result[field.id] = string(from: date, kind: field.kind)
            case .file(let url):
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                result[field.id] = ["name": url.lastPathComponent, "path": url.path(percentEncoded: false), "size": size] as [String: Any]
            }
        }
        return result
    }

    static func string(from date: Date, kind: FormField.Kind) -> String {
        switch kind {
        case .date:
            return formatter("yyyy-MM-dd").string(from: date)
        case .time:
            return formatter("HH:mm").string(from: date)
        default:
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            formatter.timeZone = .current
            return formatter.string(from: date)
        }
    }

    static func date(from text: String, kind: FormField.Kind, now: Date = Date()) -> Date? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if kind == .time {
            guard let time = formatter("HH:mm").date(from: String(text.prefix(5))) else { return nil }
            let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
            return Calendar.current.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: 0, of: now)
        }

        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            iso.formatOptions = options
            if let date = iso.date(from: text) { return date }
        }
        // Without a UTC offset the text means local time.
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            if let date = formatter(format).date(from: text) { return date }
        }
        return nil
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter
    }
}
