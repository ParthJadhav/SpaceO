import Foundation

/// Bounds the caller's wait, not the underlying synchronous WindowServer IPC. A timed-out
/// operation remains on this one worker; no replacement workers or subsequent mutations run.
/// Retaining its context prevents ARC from turning a late result into an unplanned teardown.
final class DisplayLifecycleCoordinator: @unchecked Sendable {
    final class Operation: @unchecked Sendable {
        private let lock = NSLock()
        private var retained: [AnyObject] = []
        let deadline: DispatchTime
        private let checkHealth: @Sendable () throws -> Void

        init(deadline: DispatchTime, checkHealth: @escaping @Sendable () throws -> Void) {
            self.deadline = deadline
            self.checkHealth = checkHealth
        }

        func retain(_ value: AnyObject) { lock.withLock { retained.append(value) } }
        func check() throws { try checkHealth() }
    }

    private final class Completion<T>: @unchecked Sendable {
        let lock = NSLock()
        let signal = DispatchSemaphore(value: 0)
        var result: Result<T, Error>?
    }

    private let queue = DispatchQueue(label: "spaceo.display-lifecycle")
    private let failureQueue = DispatchQueue(label: "spaceo.display-lifecycle-failure")
    private let lock = NSLock()
    private var failure: String?
    private var operations: [UUID: Operation] = [:]
    private var quarantined: [ObjectIdentifier: AnyObject] = [:]
    private let onFailure: @Sendable (String) -> Void

    init(onFailure: @escaping @Sendable (String) -> Void = { _ in }) {
        self.onFailure = onFailure
    }

    var failureReason: String? { lock.withLock { failure } }

    func check() throws {
        if let reason = failureReason { throw SpaceOError.stageCreationFailed(reason) }
    }

    func trip(_ reason: String) {
        let first = lock.withLock { () -> Bool in
            guard failure == nil else { return false }
            failure = "display safety circuit is open: \(reason); stop live work and inspect "
                + "docs/DISPLAY_SAFETY.md before recovery"
            return true
        }
        if first {
            // The lifecycle worker may be stuck holding the journal lock in fsync. Never
            // make the timeout caller wait for that same lock (or for logging/filesystem I/O).
            // Give normal persistence a short bounded chance to finish before returning.
            let saved = DispatchSemaphore(value: 0)
            failureQueue.async { [onFailure] in
                onFailure(reason)
                saved.signal()
            }
            _ = saved.wait(timeout: .now() + .milliseconds(100))
        }
    }

    func perform<T>(
        timeout: TimeInterval,
        retaining value: AnyObject? = nil,
        _ body: @escaping @Sendable (Operation) throws -> T
    ) throws -> T {
        let seconds = timeout.isFinite ? min(max(timeout, 0.1), 30) : 10
        let deadline = DispatchTime.now() + seconds
        let operation = Operation(deadline: deadline) { [weak self] in
            guard let self else {
                throw SpaceOError.stageCreationFailed("display lifecycle owner no longer exists")
            }
            if DispatchTime.now() >= deadline {
                self.trip("a display operation exhausted its total deadline")
            }
            try self.check()
        }
        if let value { operation.retain(value) }
        let id = UUID()
        // Keep contexts even on refusal after a failure: releasing a display-owning object
        // here could mutate the already unhealthy graph. Production stages are finite-budgeted.
        let admitted = lock.withLock { () -> Bool in
            guard failure == nil, operations.count < 16 else {
                if let value { quarantined[ObjectIdentifier(value)] = value }
                return false
            }
            operations[id] = operation
            return true
        }
        guard admitted else {
            trip("too many pending lifecycle operations or an earlier lifecycle failure")
            try check()
            throw SpaceOError.stageCreationFailed("display lifecycle admission refused")
        }
        let completion = Completion<T>()
        queue.async {
            let result = Result { () throws -> T in
                try operation.check()
                return try body(operation)
            }
            completion.lock.withLock { completion.result = result }
            completion.signal.signal()
        }
        guard completion.signal.wait(timeout: deadline) == .success else {
            trip("a display operation exceeded \(seconds) seconds; its delivery is unknown")
            try check()
            throw SpaceOError.stageCreationFailed("display lifecycle timed out")
        }
        // A queued call may have timed out while this one was running. Never publish its result
        // as success once any caller has declared the shared lifecycle unhealthy.
        try lock.withLock {
            if let failure { throw SpaceOError.stageCreationFailed(failure) }
            operations.removeValue(forKey: id)
        }
        return try completion.lock.withLock {
            guard let result = completion.result else {
                throw SpaceOError.stageCreationFailed("display operation completed without a result")
            }
            return try result.get()
        }
    }
}
