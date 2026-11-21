import Foundation

/// When a script runs by itself, as written after `// @schedule`.
///
/// Accepts plain phrases and cron expressions:
///
///     every 15 minutes          every 2 hours             hourly
///     every day at 09:00        daily at 9am, 5:30pm
///     weekdays at 09:00         weekends at noon
///     monday at 08:00           mon, thu at 18:30         mon-fri at 9:00
///     0 9 * * 1-5               (minute hour day-of-month month day-of-week)
///
/// Times are in the Mac's own time zone.
public struct Schedule: Hashable, Sendable {
    public struct ParseError: Error, Hashable, CustomStringConvertible {
        public let description: String
    }

    /// One "these minutes of these hours on these days" pattern, cron-style.
    /// A schedule is one or more of them.
    struct Rule: Hashable, Sendable {
        var minutes: Set<Int>
        var hours: Set<Int>
        var daysOfMonth = Set(1...31)
        var months = Set(1...12)
        /// 0 is Sunday.
        var weekdays = Set(0...6)
    }

    /// The schedule as it was written.
    public let text: String
    let rules: [Rule]

    public init(_ text: String) throws {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { throw ParseError(description: "The schedule is empty.") }
        self.text = cleaned

        let words = cleaned.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        if words.count == 5, let first = words[0].first, first.isNumber || first == "*" {
            rules = [try Self.cron(words)]
        } else {
            rules = try Self.phrase(words.joined(separator: " "), original: cleaned)
        }
    }

    /// The first time this schedule fires strictly after `date`, to the minute.
    public func next(after date: Date, calendar: Calendar = .current) -> Date? {
        rules.compactMap { $0.next(after: date, calendar: calendar) }.min()
    }

    // MARK: - Phrases

    private static func phrase(_ text: String, original: String) throws -> [Rule] {
        func unreadable() -> ParseError {
            ParseError(description: "Can't read the schedule “\(original)”. Try “every 15 minutes”, “every day at 09:00”, “weekdays at 9:00”, “mon, thu at 18:30”, or a cron expression like “0 9 * * 1-5”.")
        }
        var rest = text
        if rest.hasPrefix("every ") { rest.removeFirst(6) }

        switch rest {
        case "minute": return [Rule(minutes: Set(0...59), hours: Set(0...23))]
        case "hour", "hourly": return [Rule(minutes: [0], hours: Set(0...23))]
        default: break
        }

        if let match = rest.wholeMatch(of: /(\d+) ?(m|min|mins|minute|minutes|h|hr|hrs|hour|hours)/) {
            let count = Int(match.1) ?? 0
            if match.2.hasPrefix("m") {
                // Sets of minutes can only express intervals that fit an hour evenly.
                guard count > 0, 60 % count == 0 else {
                    throw ParseError(description: "“every \(count) minutes” doesn't divide an hour evenly. Use 1, 2, 3, 4, 5, 6, 10, 12, 15, 20 or 30 minutes.")
                }
                return [Rule(minutes: Set(stride(from: 0, to: 60, by: count)), hours: Set(0...23))]
            }
            guard count > 0, 24 % count == 0 else {
                throw ParseError(description: "“every \(count) hours” doesn't divide a day evenly. Use 1, 2, 3, 4, 6, 8 or 12 hours.")
            }
            return [Rule(minutes: [0], hours: Set(stride(from: 0, to: 24, by: count)))]
        }

        // "<days> at <times>"
        let parts = rest.split(separator: " at ", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            if (try? days(rest)) != nil {
                throw ParseError(description: "“\(original)” needs a time, like “\(original) at 09:00”.")
            }
            throw unreadable()
        }
        let weekdays = try days(String(parts[0]))
        return try times(String(parts[1])).map { time in
            Rule(minutes: [time.minute], hours: [time.hour], weekdays: weekdays)
        }
    }

    private static let dayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    private static func day(_ word: String) throws -> Int {
        let name = word.trimmingCharacters(in: .whitespaces)
        let full = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        for (index, short) in dayNames.enumerated() where name == short || name == full[index] || name == full[index] + "s" {
            return index
        }
        throw ParseError(description: "“\(name)” is not a day. Use day names like “monday” or “mon”, or “weekdays”, “weekends”, “day”.")
    }

    private static func days(_ text: String) throws -> Set<Int> {
        var result: Set<Int> = []
        for item in list(text) {
            switch item {
            case "day", "daily", "days": result.formUnion(0...6)
            case "weekday", "weekdays": result.formUnion(1...5)
            case "weekend", "weekends": result.formUnion([0, 6])
            default:
                let ends = item.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
                if ends.count == 2 {
                    // A range may wrap around the week: fri-mon.
                    var index = try day(ends[0])
                    let last = try day(ends[1])
                    result.insert(index)
                    while index != last {
                        index = (index + 1) % 7
                        result.insert(index)
                    }
                } else {
                    result.insert(try day(item))
                }
            }
        }
        guard !result.isEmpty else { throw ParseError(description: "The schedule names no day.") }
        return result
    }

    private static func times(_ text: String) throws -> [(hour: Int, minute: Int)] {
        let items = list(text)
        guard !items.isEmpty else { throw ParseError(description: "The schedule has no time after “at”.") }
        return try items.map { item in
            if item == "noon" { return (12, 0) }
            if item == "midnight" { return (0, 0) }
            guard let match = item.wholeMatch(of: /(\d{1,2})(?::(\d{2}))? ?(am|pm)?/),
                  var hour = Int(match.1) else {
                throw ParseError(description: "“\(item)” is not a time. Write it like “09:00”, “17:30” or “9am”.")
            }
            let minute = match.2.flatMap { Int($0) } ?? 0
            if let half = match.3 {
                guard (1...12).contains(hour) else {
                    throw ParseError(description: "“\(item)” is not a time: with am or pm the hour goes from 1 to 12.")
                }
                hour = hour % 12 + (half == "pm" ? 12 : 0)
            }
            guard (0...23).contains(hour), (0...59).contains(minute) else {
                throw ParseError(description: "“\(item)” is not a time of day.")
            }
            return (hour, minute)
        }
    }

    /// Splits "a, b and c" into its items.
    private static func list(_ text: String) -> [String] {
        text.replacing(" and ", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Cron

    private static func cron(_ fields: [String]) throws -> Rule {
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        var weekdays = try cronField(fields[4], name: "day of week", range: 0...7, names: dayNames, offset: 0)
        // Cron allows 7 as another name for Sunday.
        if weekdays.remove(7) != nil { weekdays.insert(0) }
        return Rule(
            minutes: try cronField(fields[0], name: "minute", range: 0...59),
            hours: try cronField(fields[1], name: "hour", range: 0...23),
            daysOfMonth: try cronField(fields[2], name: "day of month", range: 1...31),
            months: try cronField(fields[3], name: "month", range: 1...12, names: months, offset: 1),
            weekdays: weekdays
        )
    }

    /// One cron field: `*`, `5`, `1-5`, `*/15`, `1-10/2`, or a comma-separated mix.
    private static func cronField(_ field: String, name: String, range: ClosedRange<Int>, names: [String] = [], offset: Int = 0) throws -> Set<Int> {
        func bad() -> ParseError {
            ParseError(description: "The \(name) part of the cron expression, “\(field)”, should be \(range.lowerBound)-\(range.upperBound), like “*”, “5”, “1-5” or “*/15”.")
        }
        func number(_ text: Substring) throws -> Int {
            if let index = names.firstIndex(of: String(text)) { return index + offset }
            guard let value = Int(text), range.contains(value) else { throw bad() }
            return value
        }

        var values: Set<Int> = []
        for item in field.split(separator: ",", omittingEmptySubsequences: false) {
            let stepped = item.split(separator: "/", omittingEmptySubsequences: false)
            guard stepped.count <= 2, let span = stepped.first, !span.isEmpty else { throw bad() }
            var step = 1
            if stepped.count == 2 {
                guard let value = Int(stepped[1]), value > 0 else { throw bad() }
                step = value
            }

            let bounds: ClosedRange<Int>
            if span == "*" {
                bounds = range
            } else {
                let ends = span.split(separator: "-", omittingEmptySubsequences: false)
                guard ends.count <= 2 else { throw bad() }
                let first = try number(ends[0])
                // "5/10" means "from 5 on, every 10".
                let last = ends.count == 2 ? try number(ends[1]) : (stepped.count == 2 ? range.upperBound : first)
                guard first <= last else { throw bad() }
                bounds = first...last
            }
            values.formUnion(stride(from: bounds.lowerBound, through: bounds.upperBound, by: step))
        }
        return values
    }
}

extension Schedule.Rule {
    func next(after date: Date, calendar: Calendar) -> Date? {
        // Whole minutes only: the first candidate is the minute after `date`.
        guard let minute = calendar.dateInterval(of: .minute, for: date),
              let earliest = calendar.date(byAdding: .minute, value: 1, to: minute.start) else { return nil }
        let firstDay = calendar.startOfDay(for: earliest)
        let sortedHours = hours.sorted()
        let sortedMinutes = minutes.sorted()

        // Far enough to reach 29 February from anywhere.
        for offset in 0..<(366 * 8) {
            guard let day = calendar.date(byAdding: .day, value: offset, to: firstDay) else { continue }
            let parts = calendar.dateComponents([.month, .day, .weekday], from: day)
            guard let month = parts.month, let dayOfMonth = parts.day, let weekday = parts.weekday,
                  months.contains(month) else { continue }

            // As in cron: when both the day of the month and the day of the
            // week are restricted, either one is enough.
            let onDate = daysOfMonth.contains(dayOfMonth)
            let onWeekday = weekdays.contains(weekday - 1)
            let matches = daysOfMonth.count < 31 && weekdays.count < 7 ? onDate || onWeekday : onDate && onWeekday
            guard matches else { continue }

            for hour in sortedHours {
                for minute in sortedMinutes {
                    // Nil for a time that a clock change skips on this day.
                    guard let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day, matchingPolicy: .strict),
                          candidate >= earliest else { continue }
                    return candidate
                }
            }
        }
        return nil
    }
}
