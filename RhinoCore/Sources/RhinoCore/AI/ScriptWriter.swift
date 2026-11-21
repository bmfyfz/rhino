import Foundation

/// Writes, changes and repairs scripts with Claude.
///
/// One request per job, no conversation: the model gets the script API (the
/// same `globals.d.ts` people read), a few example scripts, and the job. It
/// answers with the script's source and nothing else, which streams straight
/// into the editor.
public struct ScriptWriter: Sendable {
    public enum Job: Sendable, Equatable {
        /// A new script from a description.
        case write(instruction: String)
        /// A change to an existing script.
        case revise(source: String, instruction: String)
        /// A script whose run failed; `problem` says how.
        case fix(source: String, problem: String)
    }

    public static let model = AIService.anthropicModel
    public static let defaultBaseURL = AIService.anthropicBaseURL

    private let service: AIService
    private let session: URLSession
    /// The user's own functions, which the scripts it writes may call.
    private let shared: [SharedLibrary.Signature]

    /// Writes with any provider that is set up.
    public init(service: AIService, session: URLSession = .shared, shared: [SharedLibrary.Signature] = []) {
        self.service = service
        self.session = session
        self.shared = shared
    }

    /// Writes with Claude.
    public init(apiKey: String, baseURL: URL = ScriptWriter.defaultBaseURL, session: URLSession = .shared) {
        self.init(service: .anthropic(apiKey: apiKey, baseURL: baseURL), session: session)
    }

    /// Runs a job. Each element is the script's whole source so far, so a
    /// caller can show it as it is written; the last element is the finished
    /// script. Stop iterating (or cancel the task doing so) to cancel the
    /// request. Failures are `AIError`s.
    public func stream(_ job: Job) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    let text = try await service.write(system: Self.systemPrompt, prompt: Self.userMessage(for: job) + Self.sharedSection(shared), session: session) {
                        continuation.yield(Self.clean($0))
                    }
                    if Self.clean(text).isEmpty { throw AIError(.empty, provider: service.name) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    /// The script without anything wrapped around it: surrounding blank lines
    /// and, should the model add one anyway, a Markdown code fence.
    static func clean(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)[...]
        func isBlank(_ line: Substring) -> Bool { line.allSatisfy(\.isWhitespace) }

        while let first = lines.first, isBlank(first) { lines = lines.dropFirst() }
        if let first = lines.first, first.hasPrefix("```") { lines = lines.dropFirst() }
        while let last = lines.last, isBlank(last) { lines = lines.dropLast() }
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces) == "```" { lines = lines.dropLast() }
        while let last = lines.last, isBlank(last) { lines = lines.dropLast() }

        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Prompt

    /// What to add to a request about the user's own functions. It is part
    /// of the request, not of the instructions, which stay the same for
    /// everyone so that they can be cached.
    static func sharedSection(_ shared: [SharedLibrary.Signature]) -> String {
        guard !shared.isEmpty else { return "" }
        let list = shared.map { function in
            "- \(function.name)(\(function.parameters))" + (function.comment.isEmpty ? "" : ": \(function.comment)")
        }
        return "\n\nBesides the API, these functions of the person's own exist in every script. Use them where they fit instead of writing the same thing again:\n\n" + list.joined(separator: "\n")
    }

    static func userMessage(for job: Job) -> String {
        switch job {
        case .write(let instruction):
            """
            Write a script that does this:

            \(instruction)
            """
        case .revise(let source, let instruction):
            """
            This is the current script:

            <script>
            \(source)
            </script>

            Change it like this:

            \(instruction)
            """
        case .fix(let source, let problem):
            """
            This is the current script:

            <script>
            \(source)
            </script>

            Running it failed:

            <failure>
            \(problem)
            </failure>

            Fix the script so the run succeeds.
            """
        }
    }

    /// The same for every request, which is what lets it be cached: nothing
    /// in here may depend on the job, the time or the user.
    static let systemPrompt: String = {
        let examples = Examples.forWriter
            .map { "<example>\n\($0.source)</example>" }
            .joined(separator: "\n\n")

        return """
        You write scripts for Rhino, a Mac app that runs small automations. A script is one JavaScript file. The person asking describes what they want in plain words, runs the script with one click, and looks at what it produced. Many of them will never read the code, so the script has to explain itself while it runs.

        Your reply is put straight into the app's code editor and run. So reply with the complete script source and nothing else: no Markdown code fence, no sentence before or after it. Anything that is not JavaScript breaks the script. If you want to tell the person something, put it in a comment or, better, in an output.log() they will see when it runs.

        How scripts work here:

        - A script is plain top-level code with top-level await. There is no wrapper function and nothing to export.
        - It starts with a header: `// @name` with a short title, then `// @description` with one line saying what it does.
        - Only the globals in the API reference below exist, plus standard JavaScript built-ins. There is no fetch, require, import, npm package, setTimeout, or Node or browser API. If a job needs something outside this API, do the closest thing the API allows and say what is missing in a log line.
        - Ask for what the script needs rather than hard-coding it: input.form() for several values at once, input.ask() for one, input.file() for files. Give sensible defaults where there are any, since a default also lets the script run unattended on a schedule.
        - Never put a password, API key or token in the source. Get it with secrets.get("NAME", "what it is and where to get it"): the person is asked once, it is kept in their Keychain, and the script then also works on a schedule.
        - A script that should react only to what is new (new rows, new issues, a changed price) remembers what it has seen with memory.get() and memory.set().
        - When a step needs judgement rather than rules (summarising, classifying, pulling facts out of messy text, drafting), use ai.ask(). Pass `returns` whenever the answer is used by code, so it comes back as data and not prose. Put many items into one question instead of asking once per item: every call takes seconds and costs the person money.
        - To build on what another script already produced, read it with input.from("Name") instead of running that script again: `await input.from("Name").output("Label")`, `.file("Label")` or `.result()` fail with a clear message when that script has not run yet. Use run("Name") only when the other script has to run now.
        - When asked to run several existing scripts in order, chain run() calls and hand each result to the next: `const orders = await run("Fetch orders", input.data, { show: true }); return await run("Build report", orders, { show: true });`. `{ show: true }` puts what that script publishes on show in this run. Do not copy the other scripts' code into the new one.
        - shell("command") runs a command on the person's Mac. Use it only when the job cannot be done with the rest of the API (git, a tool they named, something only a command line program does), never to do what read(), write() or get() can do, and never with text from a file, a web page or an AI answer put into the command unchecked.
        - Say what is happening with output.log() at the steps that matter, in words a non-programmer follows.
        - When the person should hear about something without watching (a scheduled check found something, a long job is done), call notify("Title", "One line of detail") once. Do not notify for routine progress, or when there is nothing new to report.
        - Publish results in the form that reads best to a person: output.table() for rows, output.chart() for numbers worth seeing, output.image() for pictures, output.text() for a summary in words, output.file() for something to keep, and output.json() for the data itself (the last output.json() is also what a calling script receives). Give each one a .name("…"): the name is what the person sees in the app, so make it say what the thing is, with specifics from the run where that helps ("Orders in March", not "Result").
        - Let failures throw. A failed HTTP call already throws with a clear message, and the app shows the error with its line number. Add try/catch only where the script can do something useful about the failure.

        When you are given an existing script to change or fix, keep what already works and change what was asked for, then return the whole file.

        This is the complete API:

        <api_reference>
        \(API.typeDefinitions)
        </api_reference>

        These scripts show the style:

        \(examples)
        """
    }()
}

extension ScriptStore {
    /// Whether this source is still the untouched template a new script starts
    /// with, so there is nothing in it worth keeping.
    public static func isStarter(_ source: String) -> Bool {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        guard let name = ScriptHeader.parse(source)["name"] else { return false }
        return trimmed == template(name: name).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
