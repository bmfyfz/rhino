import Foundation

/// A script's `// @watch`: a folder, and optionally which of its files count.
///
///     // @watch ~/Downloads
///     // @watch ~/Documents/Invoices/*.pdf
///
/// A file that arrives in the folder starts the script, with that file as
/// its input.
public struct FolderWatch: Hashable, Sendable {
    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    public let folder: URL
    /// A file name pattern with `*` and `?`, such as "*.pdf". Nil means every file.
    public let pattern: String?

    public init(_ text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw ParseError(message: "@watch needs a folder, for example ~/Downloads or ~/Downloads/*.pdf.")
        }
        let expanded = NSString(string: trimmed).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw ParseError(message: "@watch needs a full path, starting with / or ~. “\(trimmed)” is neither.")
        }
        let last = (expanded as NSString).lastPathComponent
        if last.contains("*") || last.contains("?") {
            folder = URL(filePath: (expanded as NSString).deletingLastPathComponent, directoryHint: .isDirectory)
            pattern = last
        } else {
            folder = URL(filePath: expanded, directoryHint: .isDirectory)
            pattern = nil
        }
        if folder.path(percentEncoded: false).contains("*") {
            throw ParseError(message: "@watch can only have * in the file name, not in the folder.")
        }
    }

    /// Whether a file in the folder is one the script should run for. Hidden
    /// files and downloads still in progress never are.
    public func matches(_ file: URL) -> Bool {
        let name = file.lastPathComponent
        guard !name.hasPrefix(".") else { return false }
        let unfinished = ["download", "crdownload", "part", "partial", "tmp"]
        guard !unfinished.contains(file.pathExtension.lowercased()) else { return false }
        guard let pattern else { return true }
        return fnmatch(pattern.lowercased(), name.lowercased(), 0) == 0
    }
}
