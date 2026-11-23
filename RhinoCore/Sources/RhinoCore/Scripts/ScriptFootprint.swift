import Foundation

/// What a script reaches for outside itself, read from its code without
/// running it: the hosts it contacts, the files it writes, the secrets it
/// asks for, the commands it runs.
///
/// It is for showing a person what a script written by an AI is about to do,
/// and for noticing when a later change makes it do something new. It reads
/// what is written down: an address or a command that the script puts
/// together while it runs shows up as "worked out while running", which is
/// itself worth knowing.
public struct ScriptFootprint: Hashable, Sendable {
    public enum Item: Hashable, Sendable, Comparable {
        /// Contacts this host.
        case host(String)
        /// Contacts an address it works out while running.
        case anyHost
        /// Sends data out (POST, PUT, PATCH, DELETE, or an upload), not only fetches.
        case sends
        /// Writes this file, outside the run's own folder.
        case writes(String)
        /// Writes a file whose place it works out while running.
        case writesAnywhere
        /// Reads files from the disk by path.
        case reads
        /// Runs this shell command.
        case command(String)
        /// Runs a shell command it puts together while running.
        case anyCommand
        /// Uses this saved secret.
        case secret(String)
        /// Asks an AI model, which sends it whatever the script passes along.
        case ai
        /// Shows notifications.
        case notifies
        /// Runs this other script.
        case runs(String)
        /// Builds code from text and runs it, which hides what it does.
        case buildsCode

        /// A stable text form, for keeping what was approved.
        public var key: String {
            switch self {
            case .host(let host): "host:\(host)"
            case .anyHost: "host:*"
            case .sends: "sends"
            case .writes(let path): "write:\(path)"
            case .writesAnywhere: "write:*"
            case .reads: "reads"
            case .command(let command): "shell:\(command)"
            case .anyCommand: "shell:*"
            case .secret(let name): "secret:\(name)"
            case .ai: "ai"
            case .notifies: "notifies"
            case .runs(let name): "run:\(name)"
            case .buildsCode: "eval"
            }
        }

        public static func < (left: Item, right: Item) -> Bool { left.key < right.key }

        /// What it means, in words for the person who is asked to agree.
        public var summary: String {
            switch self {
            case .host(let host): "Contact \(host)"
            case .anyHost: "Contact an address it works out while running"
            case .sends: "Send data out, not only fetch it"
            case .writes(let path): "Write the file \(path)"
            case .writesAnywhere: "Write a file in a place it works out while running"
            case .reads: "Read files from your disk"
            case .command(let command): "Run the command: \(command)"
            case .anyCommand: "Run a command it puts together while running"
            case .secret(let name): "Use your saved secret “\(name)”"
            case .ai: "Send text to your AI provider"
            case .notifies: "Show notifications"
            case .runs(let name): "Run the script “\(name)”"
            case .buildsCode: "Build code from text and run it, which hides what it does"
            }
        }
    }

    public let items: Set<Item>

    /// Nothing outside itself: such a script only asks, computes and shows.
    public var isEmpty: Bool { items.isEmpty }

    public var keys: Set<String> { Set(items.map(\.key)) }

    /// What this footprint has that an approved set of keys does not.
    public func additions(to approved: Set<String>) -> [Item] {
        items.filter { !approved.contains($0.key) }.sorted()
    }

    public init(of source: String) {
        let text = Array(source.utf16)
        // Two copies of the same length as the source: one without comments,
        // one without comments and without what is inside strings. Calls are
        // looked for in the second, so a word in a sentence is not mistaken
        // for code; what a call is given is read from the first.
        var readable = text
        var code = text
        let space = UInt16(UInt8(ascii: " "))
        let newline = UInt16(UInt8(ascii: "\n"))
        var strings: [Range<Int>] = []
        for token in JavaScriptTokenizer.tokens(in: source) {
            switch token.kind {
            case .comment:
                for index in token.range where index < text.count && text[index] != newline {
                    readable[index] = space
                    code[index] = space
                }
            case .string:
                strings.append(token.range)
                // The quotes stay, so "(" + quote still marks a literal argument.
                for index in token.range.dropFirst().dropLast() where index < text.count && text[index] != newline {
                    code[index] = space
                }
            default:
                continue
            }
        }
        let readableText = String(utf16CodeUnits: readable, count: readable.count)
        let codeText = String(utf16CodeUnits: code, count: code.count)

        var found: Set<Item> = []

        /// Every call of one of `names`, with the text literal it is given
        /// first, if it is given one.
        func calls(_ names: String) -> [(name: String, literal: String?)] {
            guard let pattern = try? NSRegularExpression(pattern: "(?<![\\w$.])(\(names))\\s*\\(\\s*") else { return [] }
            let whole = NSRange(location: 0, length: (codeText as NSString).length)
            return pattern.matches(in: codeText, range: whole).map { match in
                let name = (codeText as NSString).substring(with: match.range(at: 1))
                let after = NSMaxRange(match.range)
                // A plain "text" or 'text' as the whole first argument; a template with ${} is not one.
                guard let string = strings.first(where: { $0.lowerBound == after }) else { return (name, nil) }
                let literal = (readableText as NSString).substring(with: NSRange(location: string.lowerBound + 1, length: max(0, string.count - 2)))
                let end = string.upperBound
                let next = end < code.count ? String(utf16CodeUnits: Array(code[end..<min(code.count, end + 40)]), count: min(40, code.count - end)).trimmingCharacters(in: .whitespacesAndNewlines).first : nil
                let isWhole = next == nil || next == "," || next == ")"
                return (name, isWhole && !literal.contains("${") ? literal : nil)
            }
        }

        // The network.
        let fetches = calls("get|post|put|patch|del|download|upload|http\\.get|http\\.post|http\\.put|http\\.patch|http\\.delete")
        let requests = calls("http\\.request")
        for call in fetches {
            if let address = call.literal, let host = URL(string: address)?.host() {
                found.insert(.host(host.lowercased()))
            } else {
                found.insert(.anyHost)
            }
            if ["post", "put", "patch", "del", "upload", "http.post", "http.put", "http.patch", "http.delete"].contains(call.name) {
                found.insert(.sends)
            }
        }
        if !requests.isEmpty {
            found.insert(.anyHost)
            found.insert(.sends)
        }

        // Files.
        for call in calls("write|file\\.write") {
            if let path = call.literal, path.hasPrefix("/") || path.hasPrefix("~") {
                found.insert(.writes(path))
            } else if call.literal == nil {
                found.insert(.writesAnywhere)
            }
            // A plain name goes into the run's own folder, which is what it is for.
        }
        if !calls("read|file\\.read|file\\.list|file\\.exists").isEmpty {
            found.insert(.reads)
        }

        // Commands, secrets, AI, notifications, other scripts.
        for call in calls("shell") {
            found.insert(call.literal.map { .command($0) } ?? .anyCommand)
        }
        for call in calls("secrets\\.get") {
            found.insert(.secret(call.literal ?? "one it names while running"))
        }
        if !calls("ai\\.ask|ai\\.image").isEmpty { found.insert(.ai) }
        if !calls("notify").isEmpty { found.insert(.notifies) }
        for call in calls("run") {
            found.insert(.runs(call.literal ?? "one it names while running"))
        }
        if !calls("eval|Function|new\\s+Function").isEmpty { found.insert(.buildsCode) }

        items = found
    }
}
