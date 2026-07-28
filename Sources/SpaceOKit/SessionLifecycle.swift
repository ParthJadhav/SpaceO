import Foundation

/// FIFO exclusion for commands that may suspend while they own mutable session state.
///
/// An actor alone is not enough: actor methods are reentrant at every `await`, so a destroy
/// request can otherwise run while launch, capture, or DevTools work is suspended.
final class SessionOperationGate: @unchecked Sendable {
    final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var gate: SessionOperationGate?

        fileprivate init(gate: SessionOperationGate) {
            self.gate = gate
        }

        func finish() {
            let owner = lock.withLock {
                let owner = gate
                gate = nil
                return owner
            }
            owner?.leave()
        }

        deinit { finish() }
    }

    private let lock = NSLock()
    private var occupied = false
    private var waiters: [CheckedContinuation<Lease, Never>] = []

    func enter() async -> Lease {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if occupied {
                    waiters.append(continuation)
                    return false
                }
                occupied = true
                return true
            }
            if resumeNow {
                continuation.resume(returning: Lease(gate: self))
            }
        }
    }

    private func leave() {
        let next = lock.withLock { () -> CheckedContinuation<Lease, Never>? in
            guard !waiters.isEmpty else {
                occupied = false
                return nil
            }
            return waiters.removeFirst()
        }
        next?.resume(returning: Lease(gate: self))
    }

    var pendingCount: Int { lock.withLock { waiters.count } }
}

/// Per-session barrier between work and teardown.
///
/// Operations acquire a lease before touching session-owned apps, windows, bridges, or the
/// display tile. Destroy marks the session unavailable immediately, waits for every existing
/// lease, performs cleanup once, and only then reports completion.
final class SessionLifecycle: @unchecked Sendable {
    enum State: Equatable, Sendable {
        case active
        case destroying
        case destroyed
    }

    final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var lifecycle: SessionLifecycle?

        fileprivate init(lifecycle: SessionLifecycle) {
            self.lifecycle = lifecycle
        }

        func finish() {
            let owner = lock.withLock {
                let owner = lifecycle
                lifecycle = nil
                return owner
            }
            owner?.finishOperation()
        }

        deinit { finish() }
    }

    private let condition = NSCondition()
    private var state: State = .active
    private var activeOperations = 0

    func beginOperation() -> Lease? {
        condition.lock()
        defer { condition.unlock() }
        guard state == .active else { return nil }
        activeOperations += 1
        return Lease(lifecycle: self)
    }

    /// Returns true only to the caller that performed cleanup.
    @discardableResult
    func destroy(cleanup: () -> Void) -> Bool {
        condition.lock()
        switch state {
        case .destroyed:
            condition.unlock()
            return false
        case .destroying:
            while state != .destroyed { condition.wait() }
            condition.unlock()
            return false
        case .active:
            state = .destroying
            while activeOperations > 0 { condition.wait() }
            condition.unlock()
        }

        cleanup()

        condition.lock()
        state = .destroyed
        condition.broadcast()
        condition.unlock()
        return true
    }

    private func finishOperation() {
        condition.lock()
        precondition(activeOperations > 0, "unbalanced session lifecycle lease")
        activeOperations -= 1
        if activeOperations == 0 { condition.broadcast() }
        condition.unlock()
    }

    var currentState: State {
        condition.lock()
        defer { condition.unlock() }
        return state
    }
}
