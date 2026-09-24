import Foundation
import Darwin

/// One display-owning SpaceO process per user. A persistent, small journal carries creation
/// attempts and an unfinished-mutation/failure latch across daemon and XCTest restarts.
/// This coordinates same-user clients; it is not a security boundary.
final class DisplayLifecycleLease: @unchecked Sendable {
    private struct Journal: Codable {
        var attempts: [TimeInterval] = []
        var pending = false
        var liveTestPending: Bool?
        var failure: String?
    }

    private let lock = NSLock()
    private let path: String
    private var descriptor: Int32 = -1
    private var journal = Journal()
    private var ownsLiveTest = false

    init(path: String = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/SpaceO/display-safety.json").path) {
        self.path = path
    }

    deinit { if descriptor >= 0 { close(descriptor) } }

    func acquire() throws {
        try lock.withLock {
            if descriptor >= 0 { try requireHealthy(); return }
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
            guard fd >= 0 else { throw refused("cannot open lifecycle journal") }
            var keep = false
            defer { if !keep { close(fd) } }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == getuid(), info.st_nlink == 1,
                  info.st_mode & 0o077 == 0, info.st_size <= 4096 else {
                throw refused("lifecycle journal is not a private bounded regular file")
            }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                throw refused("another SpaceO process owns the display lifecycle")
            }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = pread(fd, &bytes, bytes.count, 0)
            guard count >= 0, count == info.st_size else { throw refused("cannot read lifecycle journal") }
            if count > 0 {
                do { journal = try JSONDecoder().decode(Journal.self, from: Data(bytes.prefix(count))) }
                catch { throw refused("lifecycle journal is unreadable; inspection is required") }
                guard journal.attempts.count <= 12,
                      journal.attempts.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                    throw refused("invalid lifecycle history")
                }
            }
            descriptor = fd
            keep = true
            try requireHealthy()
        }
    }

    func begin(creation: Bool, now: Date = Date()) throws {
        try lock.withLock {
            guard descriptor >= 0 else { throw refused("lifecycle lease was not acquired") }
            try requireHealthy()
            if creation {
                let time = now.timeIntervalSince1970
                // Clock rollback cannot erase history or produce an unlimited admission window.
                guard journal.attempts.allSatisfy({ $0 <= time }) else {
                    throw refused("clock moved backwards; creation history must age out")
                }
                journal.attempts.removeAll { time - $0 >= 600 }
                guard journal.attempts.count < 12,
                      journal.attempts.filter({ time - $0 < 60 }).count < 4 else {
                    throw SpaceOError.resourceLimit(
                        kind: .creationRate,
                        detail: "display safety limit: at most 4 creation attempts per minute "
                            + "and 12 per ten minutes across SpaceO processes",
                        retryAfter: 60)
                }
                journal.attempts.append(time)
            }
            journal.pending = true
            try save()
        }
    }

    /// Persist admission before any case can fail, including cases that never create a Stage.
    /// This is separate from a display mutation so normal lifecycle operations can still run
    /// inside the admitted case. Another process must refuse an interrupted/failed case.
    func beginLiveTest() throws {
        try lock.withLock {
            guard descriptor >= 0 else { throw refused("lifecycle lease was not acquired") }
            try requireHealthy()
            guard !ownsLiveTest else { throw refused("a live test is already in progress") }
            journal.liveTestPending = true
            try save()
            ownsLiveTest = true
        }
    }

    func finishLiveTest() throws {
        try lock.withLock {
            try requireHealthy()
            guard ownsLiveTest else { throw refused("no live test was admitted") }
            journal.liveTestPending = nil
            try save()
            ownsLiveTest = false
        }
    }

    func finish() throws {
        try lock.withLock {
            guard journal.failure == nil else { throw refused("display safety circuit is open") }
            journal.pending = false
            try save()
        }
    }

    func trip(_ reason: String) {
        lock.withLock {
            journal.failure = String(reason.prefix(512))
            // pending was persisted BEFORE mutation, so even an unsuccessful failure write
            // still refuses a new process. Never clear it on a timeout or unknown teardown.
            if descriptor >= 0 { try? save() }
        }
    }

    private func requireHealthy() throws {
        guard journal.failure == nil, !journal.pending,
              journal.liveTestPending != true || ownsLiveTest else {
            throw refused("an earlier display mutation failed or never completed; "
                + "inspect docs/DISPLAY_SAFETY.md before recovery")
        }
    }

    private func save() throws {
        let data = try JSONEncoder().encode(journal)
        let written = data.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
        guard written == data.count, ftruncate(descriptor, off_t(data.count)) == 0,
              fsync(descriptor) == 0 else {
            journal.failure = "could not persist lifecycle state"
            throw refused("could not persist lifecycle state")
        }
    }

    private func refused(_ detail: String) -> SpaceOError {
        .stageCreationFailed(detail)
    }
}
