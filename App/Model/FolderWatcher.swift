import Foundation

/// Notices files arriving in folders, for scripts with `// @watch`.
final class FolderWatcher {
    private struct Watch {
        let source: any DispatchSourceFileSystemObject
        /// The file names that were there when last looked, so only new ones count.
        var known: Set<String>
    }

    private var watches: [URL: Watch] = [:]
    /// Called with the folder and the file once a new file has stopped growing.
    var onNewFile: ((_ folder: URL, _ file: URL) -> Void)?

    /// Watches exactly these folders: starts on new ones, lets go of the rest.
    /// Files already in a folder are not news.
    func watch(_ folders: Set<URL>) {
        for (folder, watch) in watches where !folders.contains(folder) {
            watch.source.cancel()
            watches[folder] = nil
        }
        for folder in folders where watches[folder] == nil {
            let descriptor = open(folder.path(percentEncoded: false), O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in
                // The source delivers on the main queue.
                MainActor.assumeIsolated { self?.changed(folder) }
            }
            source.setCancelHandler { close(descriptor) }
            watches[folder] = Watch(source: source, known: names(in: folder))
            source.resume()
        }
    }

    private func names(in folder: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? [])
    }

    private func changed(_ folder: URL) {
        guard var watch = watches[folder] else { return }
        let now = names(in: folder)
        let arrived = now.subtracting(watch.known)
        // A file that left may come back later and count as new again.
        watch.known = now
        watches[folder] = watch

        for name in arrived {
            let file = folder.appending(path: name)
            Task {
                guard await Self.settled(file) else { return }
                onNewFile?(folder, file)
            }
        }
    }

    /// Waits until a file has stopped growing: a copy or a download in
    /// progress shows up long before it is whole. False if it went away, is
    /// a folder, or never settles.
    private static func settled(_ file: URL) async -> Bool {
        func size() -> Int? {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { return nil }
            return values?.fileSize
        }
        var last = -1
        for _ in 0..<120 {
            guard let current = size() else { return false }
            if current == last, current > 0 { return true }
            last = current
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }
}
