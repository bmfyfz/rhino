import Foundation
import Testing
@testable import RhinoCore

/// `Schedule`: parsing intervals, days and times, and cron lines, and working out when each fires next.
@Suite struct ScheduleTests {
    /// A fixed calendar, so the tests mean the same on every machine.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text + ":00Z")!
    }

    /// The next `count` times a schedule fires after a moment, as "weekday yyyy-MM-dd HH:mm".
    private func fires(_ text: String, after start: String, count: Int = 3) throws -> [String] {
        let schedule = try Schedule(text)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE yyyy-MM-dd HH:mm"

        var moment = date(start)
        var result: [String] = []
        for _ in 0..<count {
            moment = try #require(schedule.next(after: moment, calendar: calendar))
            result.append(formatter.string(from: moment))
        }
        return result
    }

    // 2026-11-21 is a Saturday.

    @Test func intervals() throws {
        #expect(try fires("every 15 minutes", after: "2026-11-21T10:07") == ["Sat 2026-11-21 10:15", "Sat 2026-11-21 10:30", "Sat 2026-11-21 10:45"])
        #expect(try fires("every 15m", after: "2026-11-21T10:15") == ["Sat 2026-11-21 10:30", "Sat 2026-11-21 10:45", "Sat 2026-11-21 11:00"])
        #expect(try fires("every minute", after: "2026-11-21T23:58", count: 2) == ["Sat 2026-11-21 23:59", "Sun 2026-11-22 00:00"])
        #expect(try fires("hourly", after: "2026-11-21T10:07", count: 2) == ["Sat 2026-11-21 11:00", "Sat 2026-11-21 12:00"])
        #expect(try fires("every 6 hours", after: "2026-11-21T10:07") == ["Sat 2026-11-21 12:00", "Sat 2026-11-21 18:00", "Sun 2026-11-22 00:00"])
    }

    @Test func daysAndTimes() throws {
        #expect(try fires("every day at 09:00", after: "2026-11-21T09:00", count: 2) == ["Sun 2026-11-22 09:00", "Mon 2026-11-23 09:00"])
        #expect(try fires("Daily at 9am, 5:30pm", after: "2026-11-21T10:00") == ["Sat 2026-11-21 17:30", "Sun 2026-11-22 09:00", "Sun 2026-11-22 17:30"])
        #expect(try fires("weekdays at 09:00", after: "2026-11-21T10:00", count: 2) == ["Mon 2026-11-23 09:00", "Tue 2026-11-24 09:00"])
        #expect(try fires("weekends at noon", after: "2026-11-21T10:00") == ["Sat 2026-11-21 12:00", "Sun 2026-11-22 12:00", "Sat 2026-11-28 12:00"])
        #expect(try fires("every monday at 8", after: "2026-11-21T10:00", count: 2) == ["Mon 2026-11-23 08:00", "Mon 2026-11-30 08:00"])
        #expect(try fires("mon, thu at 18:30", after: "2026-11-21T10:00") == ["Mon 2026-11-23 18:30", "Thu 2026-11-26 18:30", "Mon 2026-11-30 18:30"])
        #expect(try fires("fri-mon at midnight", after: "2026-11-21T10:00") == ["Sun 2026-11-22 00:00", "Mon 2026-11-23 00:00", "Fri 2026-11-27 00:00"])
        #expect(try fires("tuesdays and fridays at 12am", after: "2026-11-21T10:00", count: 2) == ["Tue 2026-11-24 00:00", "Fri 2026-11-27 00:00"])
    }

    @Test func cron() throws {
        #expect(try fires("0 9 * * 1-5", after: "2026-11-21T10:00", count: 2) == ["Mon 2026-11-23 09:00", "Tue 2026-11-24 09:00"])
        #expect(try fires("*/20 8-9 * * *", after: "2026-11-21T08:25") == ["Sat 2026-11-21 08:40", "Sat 2026-11-21 09:00", "Sat 2026-11-21 09:20"])
        #expect(try fires("30 6 1 * *", after: "2026-11-21T10:00", count: 2) == ["Tue 2026-12-01 06:30", "Fri 2027-01-01 06:30"])
        #expect(try fires("0 0 29 feb *", after: "2026-11-21T10:00", count: 1) == ["Tue 2028-02-29 00:00"])
        #expect(try fires("0 12 * * sun,7", after: "2026-11-21T10:00", count: 1) == ["Sun 2026-11-22 12:00"])
        // Both days restricted: either one is enough, as cron does it.
        #expect(try fires("0 0 1 * mon", after: "2026-11-21T10:00") == ["Mon 2026-11-23 00:00", "Mon 2026-11-30 00:00", "Tue 2026-12-01 00:00"])
    }

    @Test func explainsWhatItCannotRead() {
        func message(_ text: String) -> String {
            do {
                _ = try Schedule(text)
                return "accepted"
            } catch {
                return "\(error)"
            }
        }
        #expect(message("every 7 minutes").contains("doesn't divide an hour evenly"))
        #expect(message("every 5 hours").contains("doesn't divide a day evenly"))
        #expect(message("weekdays").contains("needs a time, like “weekdays at 09:00”"))
        #expect(message("funday at 9:00").contains("“funday” is not a day"))
        #expect(message("monday at 25:00").contains("is not a time of day"))
        #expect(message("monday at 13pm").contains("the hour goes from 1 to 12"))
        #expect(message("whenever").contains("Try “every 15 minutes”"))
        #expect(message("61 * * * *").contains("minute part"))
        #expect(message("  ").contains("empty"))
        #expect(message("every 30 minutes") == "accepted")
    }
}
