import Foundation
import JavaScriptCore

/// Turns a script's source into a program JavaScriptCore can evaluate.
///
/// A script is plain top-level code, so it is wrapped in an async function:
/// that makes top-level `await` and an early `return` work, and gives the
/// script its globals as parameters bound to its own run. The wrapper starts
/// on the script's first line, so line numbers in errors match the file.
public enum ScriptCompiler {
    public struct CompileError: Error, Equatable, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// Names every script can use without declaring them.
    public static let globals = [
        "input", "output", "secrets", "memory", "ai",
        "get", "post", "put", "patch", "del", "http",
        "download", "upload", "read", "write", "file", "csv",
        "console", "sleep", "notify", "shell", "run",
    ]

    /// Returns an expression that evaluates to `function (api) -> Promise<returned value>`.
    ///
    /// - Parameter shared: The names of the user's shared functions, which a
    ///   script can use like the built-in ones.
    public static func wrap(_ source: String, shared: [String] = []) throws -> String {
        // Nested, so a script may declare its own `const file = ...` without
        // clashing with a global of the same name.
        let program = "(function (__api) { const { \((globals + shared).joined(separator: ", ")) } = __api; "
            + "return (async function () { \"use strict\"; "
            + source
            + "\n})(); })"

        // `import` and `export` cannot appear inside a function, so they show
        // up as syntax errors. Only then are they looked for by name, to say
        // something more useful: a line of a prompt or a comment that merely
        // starts with the word is fine.
        if firstSyntaxError(in: program) != nil {
            if let line = firstLine(matching: #"^[ \t]*import[ \t]+[^(\s]"#, in: source) {
                throw CompileError(message: "Line \(line): `import` is not supported. Scripts are single files; call another script with `await run(\"name\")`.")
            }
            if let line = firstLine(matching: #"^[ \t]*export[ \t]+"#, in: source) {
                throw CompileError(message: "Line \(line): `export` is not needed. A script is plain top-level code: read from `input`, write to `output`.")
            }
        }
        return program
    }

    /// The first mistake in a program's JavaScript, with its line; nil when it parses.
    static func firstSyntaxError(in program: String) -> String? {
        guard let context = JSContext() else { return nil }
        let text = JSStringCreateWithUTF8CString(program)
        defer { JSStringRelease(text) }
        var exception: JSValueRef?
        guard !JSCheckScriptSyntax(context.jsGlobalContextRef, text, nil, 1, &exception), let exception else { return nil }
        let error = JSValue(jsValueRef: exception, in: context)
        let message = error?.toString() ?? "SyntaxError"
        // The wrapper starts on the script's first line, so the line is the script's own.
        if let line = error?.forProperty("line"), line.isNumber {
            return "\(message) (line \(line.toInt32()))"
        }
        return message
    }

    /// What stops this source from running at all: an `import`, or a mistake
    /// in the JavaScript. Nil when it would at least start. Nothing is run.
    public static func syntaxProblem(in source: String) -> String? {
        let program: String
        do {
            program = try wrap(source)
        } catch {
            return "\(error)"
        }
        return firstSyntaxError(in: program)
    }

    private static func firstLine(matching pattern: String, in text: String) -> Int? {
        // Patterns are literals in this file, so a failure is a programming error.
        let regex = try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let start = Range(match.range, in: text)?.lowerBound else { return nil }
        return text[..<start].reduce(into: 1) { count, character in
            if character.isNewline { count += 1 }
        }
    }
}
