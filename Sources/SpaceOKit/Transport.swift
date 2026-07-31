import Foundation
import Darwin

/// Line-delimited JSON over a Unix domain socket. One request, one response, one connection.
///
/// Small and boring on purpose — this is the part that must never be the reason a debugging
/// session goes sideways. `nc -U /tmp/spaceo-501.sock` is a valid client.
public enum Transport {

    public enum TransportError: Error, CustomStringConvertible, LocalizedError {
        case socketFailed(String)
        case notRunning(String)
        case malformed(String)
        case alreadyRunning(String)

        public var errorDescription: String? { description }

        public var description: String {
            switch self {
            case .socketFailed(let why): return "socket error: \(why)"
            case .notRunning(let path):
                return """
                no SpaceO daemon listening at \(path)
                  Start one with:  spaceo daemon
                """
            case .malformed(let why): return "malformed message: \(why)"
            case .alreadyRunning(let path):
                return "a SpaceO daemon is already listening at \(path)"
            }
        }
    }

    // MARK: - Server

    /// `Server` crosses the accept thread and per-client tasks. Its mutable socket/thread state
    /// is accessed only under `stateLock`; `path` and the sendable handler are immutable.
    public final class Server: @unchecked Sendable {
        private let path: String
        private var listenFD: Int32 = -1
        private var thread: Thread?
        private var stopping = false
        private var ownsSocket = false
        private var socketDevice: dev_t?
        private var socketInode: ino_t?
        private let stateLock = NSLock()
        private let handler: @Sendable (Request) async -> Response

        public init(
            path: String,
            handler: @escaping @Sendable (Request) async -> Response
        ) {
            self.path = path
            self.handler = handler
        }

        public func start() throws {
            guard !path.isEmpty, !path.utf8.contains(0) else {
                throw TransportError.socketFailed("socket path is empty or contains a NUL byte")
            }
            guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
                throw TransportError.socketFailed("socket path too long: \(path)")
            }
            let mayStart = stateLock.withLock {
                guard listenFD < 0, self.thread == nil, !ownsSocket else { return false }
                stopping = false
                return true
            }
            guard mayStart else { throw TransportError.alreadyRunning(path) }

            // Serialise stale-socket cleanup and bind. Without this lock, two MCP clients
            // auto-starting together can each unlink the other's live socket and strand a daemon.
            let lockPath = path + ".lock"
            let lockFD = Darwin.open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                                     S_IRUSR | S_IWUSR)
            guard lockFD >= 0 else {
                throw TransportError.socketFailed("open startup lock: \(errno)")
            }
            guard flock(lockFD, LOCK_EX) == 0 else {
                close(lockFD)
                throw TransportError.socketFailed("lock startup file: \(errno)")
            }
            defer {
                _ = flock(lockFD, LOCK_UN)
                close(lockFD)
            }

            var existing = stat()
            if lstat(path, &existing) == 0 {
                guard existing.st_mode & S_IFMT == S_IFSOCK else {
                    throw TransportError.socketFailed(
                        "refusing to replace non-socket path: \(path)")
                }
                if Transport.ping(path) {
                    throw TransportError.alreadyRunning(path)
                }
                if Transport.canConnect(path) {
                    throw TransportError.socketFailed(
                        "socket path is occupied by a listener that is not SpaceO: \(path)")
                }
                guard unlink(path) == 0 else {
                    throw TransportError.socketFailed("remove stale socket: \(errno)")
                }
            } else if errno != ENOENT {
                throw TransportError.socketFailed("inspect socket path: \(errno)")
            }

            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw TransportError.socketFailed("socket(): \(errno)") }
            var noSignal: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                       socklen_t(MemoryLayout<Int32>.size))

            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let maxLength = MemoryLayout.size(ofValue: address.sun_path)
            guard path.utf8.count < maxLength else {
                close(fd); throw TransportError.socketFailed("socket path too long: \(path)")
            }
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: maxLength) { dst in
                    _ = strcpy(dst, path)
                }
            }
            let size = socklen_t(MemoryLayout<sockaddr_un>.size)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
            }
            guard bound == 0 else { close(fd); throw TransportError.socketFailed("bind(): \(errno)") }
            guard chmod(path, 0o600) == 0 else {
                let failure = errno
                close(fd)
                unlink(path)
                throw TransportError.socketFailed("chmod(): \(failure)")
            }
            guard listen(fd, 16) == 0 else {
                let failure = errno
                close(fd)
                unlink(path)
                throw TransportError.socketFailed("listen(): \(failure)")
            }

            var identity = stat()
            guard lstat(path, &identity) == 0 else {
                let failure = errno
                close(fd)
                unlink(path)
                throw TransportError.socketFailed(
                    "inspect newly bound socket: \(failure)")
            }
            let thread = Thread { [weak self] in self?.acceptLoop() }
            thread.name = "spaceo.daemon.accept"
            stateLock.withLock {
                listenFD = fd
                ownsSocket = true
                socketDevice = identity.st_dev
                socketInode = identity.st_ino
                self.thread = thread
            }
            thread.start()
        }

        private func acceptLoop() {
            defer { stateLock.withLock { thread = nil } }
            while true {
                let fd = stateLock.withLock { stopping ? -1 : listenFD }
                guard fd >= 0 else { return }
                let client = accept(fd, nil, nil)
                if client < 0 {
                    if stateLock.withLock({ stopping }) { return }
                    if errno == EINTR { continue }
                    return
                }
                serve(client)
            }
        }

        private func serve(_ client: Int32) {
            var noSignal: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                       socklen_t(MemoryLayout<Int32>.size))
            // A client that connects but never sends a newline must not monopolise the only
            // accept thread forever.
            var receiveTimeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout,
                       socklen_t(MemoryLayout<timeval>.size))
            var sendTimeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout,
                       socklen_t(MemoryLayout<timeval>.size))
            let deadline = DispatchTime.now().uptimeNanoseconds &+ 3_000_000_000
            guard let line = Transport.readLine(
                from: client,
                maximumBytes: 1_048_576,
                deadlineUptimeNanoseconds: deadline) else {
                close(client)
                return
            }
            Task {
                let response: Response
                do {
                    let request = try Wire.decoder.decode(Request.self, from: Data(line.utf8))
                    response = await self.handler(request)
                } catch {
                    response = .failure(TransportError.malformed("\(error)"))
                }
                Transport.write(response, to: client)
                close(client)
            }
        }

        public func stop() {
            let state: (fd: Int32, unlink: Bool, device: dev_t?, inode: ino_t?) =
                stateLock.withLock {
                    stopping = true
                    let snapshot = (listenFD, ownsSocket, socketDevice, socketInode)
                    listenFD = -1
                    ownsSocket = false
                    socketDevice = nil
                    socketInode = nil
                    return snapshot
                }
            if state.fd >= 0 {
                shutdown(state.fd, SHUT_RDWR)
                close(state.fd)
            }
            if state.unlink {
                var current = stat()
                if lstat(path, &current) == 0,
                   current.st_dev == state.device,
                   current.st_ino == state.inode {
                    unlink(path)
                }
            }
        }
    }

    // MARK: - Client

    public static func send(_ request: Request, to path: String, timeout: TimeInterval = 60) throws -> Response {
        let payload = try Wire.encoder.encode(request)
        guard payload.count <= 1_048_576 else {
            throw TransportError.malformed("request exceeds the 1 MiB wire limit")
        }
        let response = try sendLinePayload(
            payload,
            to: path,
            timeout: timeout,
            maximumRequestBytes: 1_048_576,
            maximumResponseBytes: 8 * 1_048_576)
        return try Wire.decoder.decode(Response.self, from: response)
    }

    /// Bounded one-request/one-response Unix-socket exchange shared by the daemon wire protocol
    /// and private semantic renderer adapters.
    static func sendLinePayload(
        _ unframedPayload: Data,
        to path: String,
        timeout: TimeInterval,
        maximumRequestBytes: Int,
        maximumResponseBytes: Int
    ) throws -> Data {
        guard timeout.isFinite, timeout > 0, timeout <= 3_600 else {
            throw TransportError.socketFailed(
                "timeout must be a finite value greater than zero and at most 3600 seconds")
        }
        guard maximumRequestBytes > 0, maximumResponseBytes > 0,
              unframedPayload.count <= maximumRequestBytes else {
            throw TransportError.malformed("request exceeds its wire limit")
        }
        var payload = unframedPayload
        payload.append(0x0A)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TransportError.socketFailed("socket(): \(errno)") }
        defer { close(fd) }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                   socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        guard !path.isEmpty, !path.utf8.contains(0), path.utf8.count < maxLength else {
            throw TransportError.socketFailed("socket path too long: \(path)")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maxLength) { dst in
                _ = strcpy(dst, path)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        try connect(fd: fd, address: &address, size: size, timeout: timeout, path: path)

        let wholeSeconds = floor(timeout)
        var tv = timeval(
            tv_sec: Int(wholeSeconds),
            tv_usec: Int32((timeout - wholeSeconds) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        try payload.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let n = Foundation.write(fd, buffer.baseAddress!.advanced(by: sent), buffer.count - sent)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { throw TransportError.socketFailed("write(): \(errno)") }
                sent += n
            }
        }

        let deadline = DispatchTime.now().uptimeNanoseconds
            &+ UInt64(timeout * 1_000_000_000)
        guard let line = readLine(
            from: fd,
            maximumBytes: maximumResponseBytes,
            deadlineUptimeNanoseconds: deadline) else {
            throw TransportError.socketFailed(
                "peer closed the connection, timed out, or exceeded the response limit")
        }
        return Data(line.utf8)
    }

    // MARK: - Framing

    private static func connect(
        fd: Int32,
        address: inout sockaddr_un,
        size: socklen_t,
        timeout: TimeInterval,
        path: String
    ) throws {
        let priorFlags = fcntl(fd, F_GETFL)
        guard priorFlags >= 0,
              fcntl(fd, F_SETFL, priorFlags | O_NONBLOCK) == 0 else {
            throw TransportError.socketFailed("could not make connect nonblocking: \(errno)")
        }

        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, size)
            }
        }
        if result == 0 {
            _ = fcntl(fd, F_SETFL, priorFlags)
            return
        }
        guard errno == EINPROGRESS || errno == EAGAIN else {
            throw TransportError.notRunning(path)
        }

        var descriptor = pollfd(
            fd: fd, events: Int16(POLLOUT), revents: 0)
        let milliseconds = Int32(min(3_600_000, ceil(timeout * 1_000)))
        var ready: Int32
        repeat {
            ready = Darwin.poll(&descriptor, 1, milliseconds)
        } while ready < 0 && errno == EINTR
        guard ready > 0 else {
            throw TransportError.socketFailed(
                ready == 0 ? "connect timed out" : "connect poll failed: \(errno)")
        }

        var socketError: Int32 = 0
        var errorLength = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(
            fd, SOL_SOCKET, SO_ERROR, &socketError, &errorLength) == 0 else {
            throw TransportError.socketFailed("connect status failed: \(errno)")
        }
        guard socketError == 0 else { throw TransportError.notRunning(path) }
        _ = fcntl(fd, F_SETFL, priorFlags)
    }

    static func readLine(
        from fd: Int32,
        maximumBytes: Int = 8 * 1_048_576,
        deadlineUptimeNanoseconds: UInt64? = nil
    ) -> String? {
        guard maximumBytes > 0 else { return nil }
        var accumulated = Data()
        // Messages are typically a couple of KiB; the loop already accumulates larger ones
        // across reads, so a bigger zero-filled buffer per call would be pure waste.
        var chunk = [UInt8](repeating: 0, count: 8_192)
        while true {
            if let deadlineUptimeNanoseconds,
               DispatchTime.now().uptimeNanoseconds >= deadlineUptimeNanoseconds {
                return nil
            }
            let n = read(fd, &chunk, chunk.count)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { break }
            // The protocol is one message per connection, so nothing ever reads the bytes
            // after the newline; over-reading them into this buffer loses nothing.
            let newline = chunk[0..<n].firstIndex(of: 0x0A)
            accumulated.append(contentsOf: chunk[0..<(newline ?? n)])
            guard accumulated.count <= maximumBytes else { return nil }
            if newline != nil { break }
        }
        guard !accumulated.isEmpty else { return nil }
        return String(data: accumulated, encoding: .utf8)
    }

    static func write(_ response: Response, to fd: Int32) {
        guard var payload = try? Wire.encoder.encode(response) else { return }
        if payload.count > 8 * 1_048_576 {
            guard let fallback = try? Wire.encoder.encode(
                Response.failure(TransportError.malformed(
                    "response exceeds the 8 MiB wire limit"))) else { return }
            payload = fallback
        }
        payload.append(0x0A)
        payload.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let n = Foundation.write(fd, buffer.baseAddress!.advanced(by: sent), buffer.count - sent)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { return }
                sent += n
            }
        }
    }

    /// Is a daemon alive on this socket?
    public static func ping(_ path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        var request = Request(cmd: "ping")
        request.session = nil
        return (try? send(request, to: path, timeout: 2))?.ok == true
    }

    /// Does any process currently accept connections at this path?
    ///
    /// Used only after a SpaceO ping failed. A successful connection means the pathname is
    /// occupied and must not be treated as a stale inode just because the peer speaks a
    /// different protocol or is temporarily overloaded.
    private static func canConnect(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                   socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        guard !path.isEmpty, !path.utf8.contains(0),
              path.utf8.count < maxLength else { return false }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maxLength) { dst in
                _ = strcpy(dst, path)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let priorFlags = fcntl(fd, F_GETFL)
        guard priorFlags >= 0,
              fcntl(fd, F_SETFL, priorFlags | O_NONBLOCK) == 0 else {
            return true
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, size)
            }
        }
        if result == 0 { return true }
        // An in-progress or backlogged connection still proves the pathname is occupied.
        // Only a definitive "no listener/path" result makes stale-socket removal safe.
        return errno != ECONNREFUSED && errno != ENOENT
    }
}
