import Foundation
import AppKit

/// Bounded pasteboard snapshot support for tests and diagnostics.
///
/// This is deliberately **not** a production Copy/Cut guard. `NSPasteboard` has no
/// compare-and-swap or transaction primitive, so no snapshot/restore bracket can prove that it
/// is not overwriting a newer user clipboard between its final check and its write. Production
/// input routes therefore refuse Command-C/X before posting any event.
public enum PasteboardGuard {

    public struct Limits: Sendable {
        public let maximumItems: Int
        public let maximumTypes: Int
        public let maximumBytesPerValue: Int
        public let maximumTotalBytes: Int
        public let snapshotTimeout: TimeInterval

        public static let boundedDiagnostic = Limits()

        public init(
            maximumItems: Int = 32,
            maximumTypes: Int = 128,
            maximumBytesPerValue: Int = 16 * 1_048_576,
            maximumTotalBytes: Int = 32 * 1_048_576,
            snapshotTimeout: TimeInterval = 0.25
        ) {
            // Hard ceilings prevent a diagnostic caller from turning this utility back into an
            // unbounded pasteboard read.
            self.maximumItems = min(max(maximumItems, 0), 64)
            self.maximumTypes = min(max(maximumTypes, 0), 256)
            self.maximumBytesPerValue =
                min(max(maximumBytesPerValue, 0), 32 * 1_048_576)
            self.maximumTotalBytes =
                min(max(maximumTotalBytes, 0), 64 * 1_048_576)
            guard snapshotTimeout.isFinite else {
                self.snapshotTimeout = 0.25
                return
            }
            self.snapshotTimeout = min(max(snapshotTimeout, 0), 1)
        }
    }

    public enum SnapshotFailure: Equatable, Sendable {
        case tooManyItems(limit: Int)
        case tooManyTypes(limit: Int)
        case valueTooLarge(limit: Int)
        case aggregateTooLarge(limit: Int)
        case valueUnavailable
        case timedOut
        case changedDuringCapture
    }

    public struct Snapshot {
        let items: [[String: Data]]
        let changeCount: Int
        public let failure: SnapshotFailure?

        public var isEmpty: Bool { items.isEmpty }
        public var typeCount: Int { items.reduce(0) { $0 + $1.count } }
        public var isComplete: Bool { failure == nil }
    }

    public static func snapshot() -> Snapshot {
        snapshot(from: .general)
    }

    public static func snapshot(
        from pasteboard: NSPasteboard,
        limits: Limits = .boundedDiagnostic
    ) -> Snapshot {
        capture(from: pasteboard, limits: limits)
    }

    /// Diagnostic/test helper. This is not a conditional restore and must never be used around
    /// production shared-pasteboard mutations.
    @discardableResult
    public static func restore(_ snapshot: Snapshot) -> Bool {
        restore(snapshot, to: .general)
    }

    @discardableResult
    public static func restore(_ snapshot: Snapshot, to pasteboard: NSPasteboard) -> Bool {
        guard snapshot.isComplete else { return false }
        let current = Self.snapshot(from: pasteboard)
        guard current.isComplete, current.items != snapshot.items else { return false }
        return write(snapshot, to: pasteboard)
    }

    /// Internal test/demo convenience only. It deliberately has no production callers.
    static func preserving<T>(
        pasteboard: NSPasteboard = .general,
        _ body: () throws -> T
    ) rethrows -> T {
        let saved = snapshot(from: pasteboard)
        defer {
            if saved.isComplete {
                _ = restore(saved, to: pasteboard)
            }
        }
        return try body()
    }

    /// Internal test convenience only. Production Copy/Cut routes fail closed before dispatch.
    static func preserving<T>(_ body: () async throws -> T) async rethrows -> T {
        let saved = snapshot()
        defer {
            if saved.isComplete {
                _ = restore(saved)
            }
        }
        return try await body()
    }

    // MARK: - Bounded diagnostic capture

    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Data?

        func store(_ value: Data?) {
            lock.lock()
            self.value = value
            lock.unlock()
        }

        func load() -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    /// AppKit does not declare `NSPasteboardItem` Sendable. Capture transfers this wrapper to
    /// exactly one diagnostic worker, and the caller never accesses the item again until that
    /// worker signals completion (or returns permanently after a timeout).
    private final class ProviderValueRead: @unchecked Sendable {
        private let item: NSPasteboardItem
        private let type: NSPasteboard.PasteboardType

        init(item: NSPasteboardItem, type: NSPasteboard.PasteboardType) {
            self.item = item
            self.type = type
        }

        func load() -> Data? {
            autoreleasepool { item.data(forType: type) }
        }
    }

    /// A provider that never returns consumes at most one diagnostic worker. Further snapshots
    /// fail fast. This trade-off is another reason this utility is not a production guard.
    private final class ProviderReadGate: @unchecked Sendable {
        private let lock = NSLock()
        private var readInFlight = false

        func acquire() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !readInFlight else { return false }
            readInFlight = true
            return true
        }

        func release() {
            lock.lock()
            readInFlight = false
            lock.unlock()
        }
    }

    private static let providerReadGate = ProviderReadGate()

    private static func capture(
        from pasteboard: NSPasteboard,
        limits: Limits
    ) -> Snapshot {
        let initialChangeCount = pasteboard.changeCount
        let pasteboardItems = pasteboard.pasteboardItems ?? []
        guard pasteboardItems.count <= limits.maximumItems else {
            return Snapshot(
                items: [], changeCount: initialChangeCount,
                failure: .tooManyItems(limit: limits.maximumItems))
        }

        let deadline = DispatchTime.now()
            + .nanoseconds(Int(limits.snapshotTimeout * 1_000_000_000))
        var captured: [[String: Data]] = []
        captured.reserveCapacity(pasteboardItems.count)
        var typeCount = 0
        var totalBytes = 0

        for item in pasteboardItems {
            let types = item.types
            typeCount += types.count
            guard typeCount <= limits.maximumTypes else {
                return Snapshot(
                    items: [], changeCount: initialChangeCount,
                    failure: .tooManyTypes(limit: limits.maximumTypes))
            }

            var payload: [String: Data] = [:]
            payload.reserveCapacity(types.count)
            for type in types {
                guard providerReadGate.acquire() else {
                    return Snapshot(
                        items: [], changeCount: initialChangeCount, failure: .timedOut)
                }
                let box = DataBox()
                let completed = DispatchSemaphore(value: 0)
                let read = ProviderValueRead(item: item, type: type)
                // Off-main execution makes the diagnostic deadline enforceable. An in-process
                // test NSPasteboardItemDataProvider makes AppKit log a synchronous-promise
                // warning here; production SpaceO registers no such provider.
                DispatchQueue.global(qos: .userInitiated).async {
                    box.store(read.load())
                    providerReadGate.release()
                    completed.signal()
                }
                guard completed.wait(timeout: deadline) == .success else {
                    return Snapshot(
                        items: [], changeCount: initialChangeCount, failure: .timedOut)
                }
                guard let data = box.load() else {
                    return Snapshot(
                        items: [], changeCount: initialChangeCount,
                        failure: .valueUnavailable)
                }
                // NSPasteboard materialises values atomically, so this bounds retained bytes,
                // not a malicious provider's transient allocation.
                guard data.count <= limits.maximumBytesPerValue else {
                    return Snapshot(
                        items: [], changeCount: initialChangeCount,
                        failure: .valueTooLarge(limit: limits.maximumBytesPerValue))
                }
                guard totalBytes <= limits.maximumTotalBytes - data.count else {
                    return Snapshot(
                        items: [], changeCount: initialChangeCount,
                        failure: .aggregateTooLarge(limit: limits.maximumTotalBytes))
                }
                totalBytes += data.count
                payload[type.rawValue] = data
            }
            captured.append(payload)
        }

        let finalChangeCount = pasteboard.changeCount
        guard finalChangeCount == initialChangeCount else {
            return Snapshot(
                items: [], changeCount: finalChangeCount, failure: .changedDuringCapture)
        }
        return Snapshot(items: captured, changeCount: finalChangeCount, failure: nil)
    }

    @discardableResult
    private static func write(_ snapshot: Snapshot, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return true }

        let restored = snapshot.items.map { payload -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in payload {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        return pasteboard.writeObjects(restored)
    }
}
