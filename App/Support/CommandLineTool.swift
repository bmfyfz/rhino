import Foundation

/// The `rhino` command line tool that ships inside the app, and the link
/// that puts it where a terminal finds it.
enum CommandLineTool {
    /// The tool inside this copy of the app. Nil in a build that has none.
    static var bundled: URL? {
        let url = Bundle.main.bundleURL.appending(path: "Contents/Helpers/rhino")
        return FileManager.default.isExecutableFile(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    /// Folders a terminal usually looks in, best first. The last one can
    /// always be written, but may not be looked in.
    private static let folders = ["/usr/local/bin", "/opt/homebrew/bin", NSHomeDirectory() + "/.local/bin"]

    /// Where a link to this app's tool is, if there is one.
    static var installedAt: String? {
        guard let target = bundled?.path(percentEncoded: false) else { return nil }
        return folders.map { $0 + "/rhino" }.first {
            (try? FileManager.default.destinationOfSymbolicLink(atPath: $0)) == target
        }
    }

    struct Problem: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Links the tool into the first of the folders that can be written,
    /// and returns the link's path. A `rhino` that is already there is
    /// replaced only if it is a link too: a real file is somebody's program.
    static func install() throws -> String {
        guard let target = bundled?.path(percentEncoded: false) else {
            throw Problem(message: "This build of Rhino has no command line tool in it. Build it with Tools/install.sh.")
        }
        let files = FileManager.default
        var reasons: [String] = []
        for folder in folders {
            let link = folder + "/rhino"
            do {
                if folder == folders.last { try files.createDirectory(atPath: folder, withIntermediateDirectories: true) }
                guard files.isWritableFile(atPath: folder) else { continue }
                if (try? files.attributesOfItem(atPath: link)[.type] as? FileAttributeType) != nil {
                    guard (try? files.destinationOfSymbolicLink(atPath: link)) != nil else {
                        reasons.append("\(link) is another program")
                        continue
                    }
                    try files.removeItem(atPath: link)
                }
                try files.createSymbolicLink(atPath: link, withDestinationPath: target)
                return link
            } catch {
                reasons.append("\(folder): \(error.localizedDescription)")
            }
        }
        throw Problem(message: "Could not install the command: " + reasons.joined(separator: "; "))
    }

    /// Whether a terminal will find a command installed at `path` without
    /// being told where it is.
    static func isOnUsualPath(_ path: String) -> Bool {
        !path.hasPrefix(NSHomeDirectory())
    }
}
