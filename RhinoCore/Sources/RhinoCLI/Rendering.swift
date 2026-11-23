import Foundation
import RhinoControl

/// What the tool prints for people. Everything here is plain text made
/// from the app's answers; `--json` prints the answers themselves instead.
public enum Render {
    // MARK: - Tables

    /// Columns padded to line up, with a heading row. The last column is
    /// not padded, so no line ends in spaces.
    public static func table(_ headings: [String], _ rows: [[String]]) -> String {
        let widths = headings.indices.map { column in
            ([headings[column]] + rows.map { $0[column] }).map(\.count).max() ?? 0
        }
        func line(_ cells: [String]) -> String {
            cells.enumerated().map { index, cell in
                index == cells.count - 1 ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }
            .joined(separator: "  ")
            .trimmingCharacters(in: .whitespaces)
        }
        return ([line(headings)] + rows.map(line)).joined(separator: "\n")
    }

    // MARK: - Times

    static func day(_ date: Date) -> String {
        date.formatted(Date.VerbatimFormatStyle(
            format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
            timeZone: .current, calendar: .current
        ))
    }

    static func clock(_ date: Date) -> String {
        date.formatted(Date.VerbatimFormatStyle(
            format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)",
            timeZone: .current, calendar: .current
        ))
    }

    public static func took(_ seconds: Double) -> String {
        if seconds < 1 { return "\(Int((seconds * 1000).rounded())) ms" }
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        let whole = Int(seconds.rounded())
        return "\(whole / 60) min \(whole % 60) s"
    }

    // MARK: - Scripts

    public static func scripts(_ scripts: [ScriptInfo]) -> String {
        guard !scripts.isEmpty else { return "No scripts yet. `rhino new \"Name\"` makes one." }
        return table(["NAME", "ID", "RUNS", "LAST RUN", "STATE"], scripts.map { script in
            [
                script.name,
                script.id,
                script.schedule ?? script.watch.map { "when a file arrives in \($0)" } ?? "",
                script.lastRun.map { "\($0.status.rawValue) \(day($0.startedAt))" } ?? "",
                script.running ? "running" : script.needsApproval ? "needs approval" : "",
            ]
        })
    }

    // MARK: - Runs

    public static func runs(_ runs: [RunBrief]) -> String {
        guard !runs.isEmpty else { return "No runs yet." }
        return table(["RUN", "SCRIPT", "STARTED", "TOOK", "STATUS", "STARTED BY"], runs.map { run in
            [run.id, run.script, day(run.startedAt), run.duration.map(took) ?? "", run.status.rawValue, startedBy(run.trigger)]
        })
    }

    static func startedBy(_ trigger: String?) -> String {
        switch trigger {
        case "schedule": "schedule"
        case "folder": "watched folder"
        case "shortcut": "Shortcuts"
        case "commandLine": "command line"
        default: "you"
        }
    }

    /// One line of a run. The script's name is shown only for lines from a
    /// script that the one being run started.
    public static func line(_ line: RunLine, root: String) -> String {
        let mark = switch line.kind {
        case .log: line.level == "error" ? "✗ " : line.level == "warn" ? "! " : ""
        case .call: ""
        case .output, .file: "→ "
        case .notification: "🔔 "
        case .question: "? "
        }
        let from = line.script == root ? "" : "[\(line.script)] "
        return "\(clock(line.time))  \(from)\(mark)\(line.text)"
    }

    /// How a run ended, in one line.
    public static func outcome(_ report: RunReport) -> String {
        let took = report.run.duration.map { " in \(Render.took($0))" } ?? ""
        switch report.run.status {
        case .running: return "Still running"
        case .finished: return "Finished\(took)"
        case .stopped: return "Stopped\(took)"
        case .failed:
            guard let error = report.error else { return "Failed\(took)" }
            let place = error.script.map { script in " (\(script).js\(error.line.map { ", line \($0)" } ?? ""))" } ?? ""
            return "Failed\(took): \(error.name): \(error.message)\(place)"
        }
    }

    /// A finished run from the history, whole.
    public static func log(_ report: RunReport) -> String {
        var lines = ["\(report.run.script) · \(day(report.run.startedAt)) · started by \(startedBy(report.run.trigger)) · run \(report.run.id)"]
        lines += report.log.map { line($0, root: report.run.script) }
        lines.append(outcome(report))
        if let result = report.result {
            lines.append("")
            lines.append(pretty(result))
        }
        return lines.joined(separator: "\n")
    }

    public static func pretty(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    // MARK: - The rest

    public static func check(_ report: CheckReport) -> String {
        var lines = [report.problem.map { "Not valid JavaScript: \($0)" } ?? "Valid JavaScript."]
        if report.problem == nil {
            if report.touches.isEmpty {
                lines.append("It reaches for nothing outside itself: it only asks, computes and shows.")
            } else {
                lines.append("When it runs, it will:")
                lines += report.touches.map { "  \($0)" }
            }
            if !report.unapproved.isEmpty {
                lines.append("Not agreed to yet, so Rhino will ask before it runs from here:")
                lines += report.unapproved.map { "  \($0)" }
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func status(_ status: StatusReport) -> String {
        var lines = ["Rhino \(status.version) · \(status.scripts) \(status.scripts == 1 ? "script" : "scripts")"]
        if !status.running.isEmpty {
            lines.append("Running:")
            lines += status.running.map { "  \($0.script), since \(clock($0.startedAt))" }
        }
        if !status.scheduled.isEmpty {
            lines.append(status.schedulesPaused ? "Schedules (paused):" : "Schedules:")
            lines.append(table(["", "SCRIPT", "SCHEDULE", "NEXT"], status.scheduled.map {
                ["", $0.script, $0.schedule, $0.problem ?? $0.next.map(day) ?? ""]
            }))
        }
        if !status.watched.isEmpty {
            lines.append("Watched folders:")
            lines.append(table(["", "SCRIPT", "FOLDER"], status.watched.map { ["", $0.script, $0.problem ?? $0.folder] }))
        }
        if !status.awaitingApproval.isEmpty {
            lines.append("Waiting for your approval in Rhino: \(status.awaitingApproval.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    public static func secrets(_ secrets: [SecretInfo]) -> String {
        guard !secrets.isEmpty else { return "No secrets are saved." }
        return table(["NAME", "USED BY"], secrets.map { [$0.name, $0.scripts.isEmpty ? "no script yet" : $0.scripts.joined(separator: ", ")] })
    }

    public static func functions(_ files: [FunctionsInfo]) -> String {
        guard !files.isEmpty else { return "No shared functions yet. `rhino functions write <name> <file>` adds a file of them." }
        return table(["FILE", "DEFINES"], files.map { [$0.name, $0.problem.map { "problem: \($0)" } ?? $0.defines.joined(separator: ", ")] })
    }
}
