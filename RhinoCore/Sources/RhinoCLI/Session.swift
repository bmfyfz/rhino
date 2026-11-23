import ArgumentParser
import Foundation
import RhinoControl

/// How a command ends when it cannot do what was asked: with a line on
/// standard error that starts with the tool's name, and a code a shell
/// script can tell apart.
enum Exit {
    /// The app did the opposite of what was hoped: a script failed, a name
    /// was unknown, the person said no.
    static let failed: Int32 = 1
    /// The app could not be reached at all.
    static let unreachable: Int32 = 2

    static func fail(_ message: String, code: Int32 = failed) -> ExitCode {
        Terminal.error("rhino: \(message)")
        return ExitCode(code)
    }
}

/// Standard output and standard error.
enum Terminal {
    static func out(_ text: String) {
        FileHandle.standardOutput.write(Data((text.hasSuffix("\n") ? text : text + "\n").utf8))
    }

    static func error(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    /// Data for other programs: stable key order, dates a person can read.
    static func json<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        out(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    static var inputIsTyped: Bool { isatty(STDIN_FILENO) != 0 }

    static func readInput() -> String {
        String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    }
}

/// Talking to the app: finding it, starting it when it is not open, and
/// turning what goes wrong into a message and an exit code.
enum Session {
    static func perform(_ request: ControlRequest, receive: (ControlMessage) -> Void = { _ in }) throws -> ControlResult {
        let client = ControlClient()
        do {
            return try ask(client, request, receive)
        } catch is ControlClient.Unreachable {
            try wake(client)
            return try ask(client, request, receive)
        }
    }

    private static func ask(_ client: ControlClient, _ request: ControlRequest, _ receive: (ControlMessage) -> Void) throws -> ControlResult {
        do {
            return try client.perform(request, receive: receive)
        } catch let refusal as ControlClient.Refusal {
            throw Exit.fail(refusal.message)
        } catch let problem as ControlError {
            throw Exit.fail(problem.message, code: Exit.unreachable)
        }
    }

    /// Nothing answered. If the person has allowed the tool, the app is
    /// probably just not open: open it and wait for it to listen.
    private static func wake(_ client: ControlClient) throws {
        let turnOn = "In Rhino, open Settings > General and turn on “Allow the rhino command line tool”."
        // A socket named by hand belongs to a test, not to the installed app.
        guard ProcessInfo.processInfo.environment["RHINO_SOCKET"] == nil else {
            throw Exit.fail("Nothing is answering at \(client.path).", code: Exit.unreachable)
        }
        let allowed = CFPreferencesCopyAppValue(ControlProtocol.enabledKey as CFString, ControlProtocol.bundleIdentifier as CFString) as? Bool ?? false
        guard allowed else {
            throw Exit.fail("Rhino is not accepting commands. \(turnOn)", code: Exit.unreachable)
        }

        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // In the background: a command in a terminal should not take the screen.
        open.arguments = ["-g", "-b", ControlProtocol.bundleIdentifier]
        open.standardError = FileHandle.nullDevice
        try? open.run()
        open.waitUntilExit()
        guard open.terminationStatus == 0 else {
            throw Exit.fail("Rhino is not installed, or could not be opened.", code: Exit.unreachable)
        }
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if client.isAnswered { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw Exit.fail("Rhino opened but is not answering. \(turnOn)", code: Exit.unreachable)
    }
}

/// Where a script's source comes from: a file, or what is piped in.
enum Source {
    /// The text of `file`, or of standard input for "-" or when nothing is
    /// named and something is piped in. Nil when there is neither.
    static func read(_ file: String?) throws -> String? {
        if let file, file != "-" {
            let url = URL(fileURLWithPath: file)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                throw Exit.fail("Could not read \(file).")
            }
            return text
        }
        if file == "-" || !Terminal.inputIsTyped {
            return Terminal.readInput()
        }
        return nil
    }

    static func required(_ file: String?) throws -> String {
        guard let text = try read(file) else {
            throw Exit.fail("Name a file with the script in it, or pipe the script in.")
        }
        return text
    }
}
