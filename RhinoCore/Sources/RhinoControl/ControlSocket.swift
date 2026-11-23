import Darwin
import Foundation
import Synchronization

/// Something went wrong between the tool and the app, said in words a
/// person can act on.
public struct ControlError: Error, LocalizedError, Equatable, Sendable {
    public let message: String
    public var errorDescription: String? { message }

    public init(_ message: String) {
        self.message = message
    }
}

// MARK: - The plumbing both ends share

enum Plumbing {
    /// The longest request or message: a script's source fits many times over.
    static let longestLine = 32 * 1024 * 1024

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        // One byte stays free for the zero that ends the path.
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw ControlError("The path of the socket is too long for macOS: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
        var address = try address(path)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    /// A stream socket that fails a write to a closed peer with an error
    /// instead of ending the whole process with SIGPIPE.
    static func socket() throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ControlError("Could not open a socket: \(reason())") }
        quiet(descriptor)
        return descriptor
    }

    static func quiet(_ descriptor: Int32) {
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func reason() -> String {
        String(cString: strerror(errno))
    }

    /// Writes all of it, or says that the other end is gone.
    static func write(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let count = Darwin.send(descriptor, buffer.baseAddress! + sent, buffer.count - sent, 0)
                if count > 0 {
                    sent += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }
}

/// Reads a socket one line at a time.
struct LineReader {
    let descriptor: Int32
    private var buffer = Data()

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// The next line without its line break. Nil when the other end closed
    /// the connection, or when it sends a line too long to be a real one.
    mutating func next() -> Data? {
        while true {
            if let end = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<end]
                buffer = Data(buffer[buffer.index(after: end)...])
                return Data(line)
            }
            guard buffer.count <= Plumbing.longestLine else { return nil }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let count = chunk.withUnsafeMutableBytes { Darwin.recv(descriptor, $0.baseAddress, $0.count, 0) }
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return nil
            }
        }
    }
}

// MARK: - The app's end

/// One request being answered. The app sends messages through it, and is
/// told when whoever asked has gone away.
public final class ControlConnection: Sendable {
    private struct State {
        var isClosed = false
        var whenClosed: [@Sendable () -> Void] = []
    }

    private let descriptor: Int32
    private let state = Mutex(State())
    /// Messages go out whole and in order, whoever sends them.
    private let sending = Mutex(())

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// Whether whoever asked is still there to hear the answer.
    public var isClosed: Bool {
        state.withLock { $0.isClosed }
    }

    /// Sends a message. Says nothing if the other end has gone: the app
    /// learns of that through `whenClosed`.
    public func send(_ message: ControlMessage) {
        guard !isClosed, let line = try? Wire.line(message) else { return }
        sending.withLock { _ in
            _ = Plumbing.write(line, to: descriptor)
        }
    }

    /// Runs `action` once the other end closes the connection: at once if
    /// it already has. This is how Control-C in a terminal stops a run.
    public func whenClosed(_ action: @escaping @Sendable () -> Void) {
        let alreadyClosed = state.withLock { state in
            if !state.isClosed { state.whenClosed.append(action) }
            return state.isClosed
        }
        if alreadyClosed { action() }
    }

    /// The answer is complete: hang up. The thread reading the connection
    /// notices and closes it.
    func finish() {
        shutdown(descriptor, SHUT_RDWR)
    }

    func markClosed() {
        let actions = state.withLock { state in
            state.isClosed = true
            defer { state.whenClosed = [] }
            return state.whenClosed
        }
        for action in actions { action() }
    }
}

/// The app's ear: accepts connections on a socket only the user can open,
/// reads one request from each and hands it to `answer`.
public final class ControlListener: Sendable {
    public typealias Answer = @Sendable (ControlRequest, ControlConnection) async -> Void

    public let path: String
    private let descriptor: Int32
    private let stopped = Mutex(false)

    /// Starts listening. Throws when the socket cannot be made, or when
    /// another copy of the app is already answering there.
    public init(path: String = ControlProtocol.socketPath, answer: @escaping Answer) throws {
        self.path = path
        guard !ControlClient(path: path).isAnswered else {
            throw ControlError("Another copy of Rhino is already answering the command line tool.")
        }
        // Whatever is at the path now is left over from a copy that has quit.
        unlink(path)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)

        let descriptor = try Plumbing.socket()
        let bound = try Plumbing.withAddress(path) { bind(descriptor, $0, $1) }
        // Nobody can connect before `listen`, so the socket is never open to
        // other users of the Mac, not even for a moment.
        guard bound == 0, chmod(path, 0o600) == 0, listen(descriptor, 16) == 0 else {
            let reason = Plumbing.reason()
            close(descriptor)
            unlink(path)
            throw ControlError("Could not listen for the command line tool: \(reason)")
        }
        self.descriptor = descriptor

        Thread.detachNewThread { [self] in
            Thread.current.name = "rhino.control.accept"
            while true {
                let client = accept(descriptor, nil, nil)
                if stopped.withLock({ $0 }) {
                    if client >= 0 { close(client) }
                    break
                }
                guard client >= 0 else {
                    if errno == EINTR || errno == ECONNABORTED { continue }
                    break
                }
                Thread.detachNewThread { Self.serve(client, answer: answer) }
            }
            close(descriptor)
        }
    }

    /// Stops listening and removes the socket. Requests being answered run on.
    public func stop() {
        let wasStopped = stopped.withLock { stopped in
            defer { stopped = true }
            return stopped
        }
        guard !wasStopped else { return }
        // The accepting thread is waiting in `accept`; a connection wakes it.
        _ = ControlClient(path: path).isAnswered
        unlink(path)
    }

    deinit {
        stop()
    }

    private static func serve(_ client: Int32, answer: @escaping Answer) {
        Thread.current.name = "rhino.control.connection"
        Plumbing.quiet(client)
        defer { close(client) }

        // The file's permissions already keep other users out; this is the
        // same check made a second way.
        var user: uid_t = 0
        var group: gid_t = 0
        guard getpeereid(client, &user, &group) == 0, user == getuid() else { return }

        // A client that connects and says nothing does not hold the thread for ever.
        var patience = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &patience, socklen_t(MemoryLayout<timeval>.size))
        var reader = LineReader(descriptor: client)
        guard let line = reader.next() else { return }
        var forever = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &forever, socklen_t(MemoryLayout<timeval>.size))

        let connection = ControlConnection(descriptor: client)
        do {
            let envelope = try Wire.decode(ControlEnvelope.self, from: line)
            guard envelope.version == ControlProtocol.version else {
                connection.send(.failed("This rhino tool and the Rhino app are of different versions. Use the tool that is inside the app: Settings > General installs it."))
                return
            }
            Task.detached {
                await answer(envelope.request, connection)
                connection.finish()
            }
        } catch {
            connection.send(.failed("The app did not understand the request. The rhino tool may be older or newer than the app."))
            return
        }

        // Nothing more is expected from the client. Reading on is how its
        // leaving is noticed, and how `finish()` is heard.
        while reader.next() != nil {}
        connection.markClosed()
    }
}

// MARK: - The tool's end

/// Asks the app one thing and reads the answer.
public struct ControlClient: Sendable {
    public let path: String

    public init(path: String = ControlProtocol.socketPath) {
        self.path = path
    }

    /// Whether anything is listening at the path right now.
    public var isAnswered: Bool {
        guard let descriptor = try? connect() else { return false }
        close(descriptor)
        return true
    }

    /// Thrown when no app is listening, as opposed to an app that said no.
    public struct Unreachable: Error, Sendable {}

    /// What the app answered a request with when it did not do it.
    public struct Refusal: Error, LocalizedError, Equatable, Sendable {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Sends a request and waits for its result. `receive` gets the
    /// messages that come before the result, as they arrive.
    @discardableResult
    public func perform(_ request: ControlRequest, receive: (ControlMessage) -> Void = { _ in }) throws -> ControlResult {
        let descriptor: Int32
        do {
            descriptor = try connect()
        } catch {
            throw Unreachable()
        }
        defer { close(descriptor) }

        guard Plumbing.write(try Wire.line(ControlEnvelope(request)), to: descriptor) else { throw Unreachable() }
        var reader = LineReader(descriptor: descriptor)
        while let line = reader.next() {
            guard !line.isEmpty else { continue }
            switch try Wire.decode(ControlMessage.self, from: line) {
            case .done(let result): return result
            case .failed(let message): throw Refusal(message: message)
            case let message: receive(message)
            }
        }
        throw ControlError("Rhino stopped answering before it was done. It may have quit.")
    }

    private func connect() throws -> Int32 {
        let descriptor = try Plumbing.socket()
        let connected = try Plumbing.withAddress(path) { Darwin.connect(descriptor, $0, $1) }
        guard connected == 0 else {
            let reason = Plumbing.reason()
            close(descriptor)
            throw ControlError(reason)
        }
        return descriptor
    }
}
