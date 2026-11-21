import Foundation

/// One command run in the user's shell, for `shell()` in scripts.
enum ShellCommand {
    struct Outcome: Sendable {
        var stdout: String
        var stderr: String
        var code: Int32
        /// The time limit ran out and the command was stopped.
        var timedOut = false
    }

    struct Unavailable: LocalizedError {
        var errorDescription: String? { "shell() is not available on this platform." }
    }

    /// The most output kept from each of the command's two streams.
    static let maxOutput = 8 * 1024 * 1024

    /// Runs `command` with zsh, as typed in a terminal, and waits for it to
    /// end. Cancelling the calling task stops the command.
    ///
    /// - Parameters:
    ///   - directory: Where it runs. Nil means the home folder.
    ///   - environment: Variables added to the ones the app has.
    ///   - input: Text fed to the command's standard input.
    ///   - timeout: Seconds after which it is stopped; nil means no limit.
    static func run(_ command: String, directory: URL?, environment: [String: String], input: String?, timeout: TimeInterval?) async throws -> Outcome {
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(filePath: "/bin/zsh")
        // A login shell, so the PATH is the one the user has in a terminal
        // (Homebrew, their own tools), not the bare one apps are given.
        process.arguments = ["-l", "-c", command]
        process.currentDirectoryURL = directory ?? FileManager.default.homeDirectoryForCurrentUser
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, added in added }

        let out = Pipe(), err = Pipe(), stdin = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = stdin

        // Both streams are read while the command runs: one that fills its
        // pipe without being read would wait forever.
        let stdout = Task { await read(out.fileHandleForReading) }
        let stderr = Task { await read(err.fileHandleForReading) }

        let state = TimeoutFlag()
        return try await withTaskCancellationHandler {
            do {
                try process.run()
            } catch {
                // Nothing will ever write to the pipes; let their readers go.
                try? out.fileHandleForWriting.close()
                try? err.fileHandleForWriting.close()
                throw error
            }
            if let input {
                stdin.fileHandleForWriting.write(Data(input.utf8))
            }
            try? stdin.fileHandleForWriting.close()

            let limit = timeout.map { seconds in
                Task {
                    try? await Task.sleep(for: .seconds(seconds))
                    guard !Task.isCancelled, process.isRunning else { return }
                    state.set()
                    process.terminate()
                }
            }
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                process.terminationHandler = { _ in done.resume() }
                // It may have ended before the handler was in place.
                if !process.isRunning {
                    process.terminationHandler = nil
                    done.resume()
                }
            }
            limit?.cancel()
            return Outcome(stdout: await stdout.value, stderr: await stderr.value, code: process.terminationStatus, timedOut: state.isSet)
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        #else
        throw Unavailable()
        #endif
    }

    #if os(macOS)
    private static func read(_ handle: FileHandle) async -> String {
        await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                var data = Data()
                while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    // Keeps reading to let the command finish, but stops keeping.
                    if data.count < maxOutput { data.append(chunk.prefix(maxOutput - data.count)) }
                }
                done.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }
    #endif

    /// Set from the timer's task, read after the command ended.
    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }
}
