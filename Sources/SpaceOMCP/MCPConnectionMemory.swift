import Foundation
import SpaceOKit

/// What one MCP connection remembers between tool calls so receipts can say only what changed.
///
/// Nothing here is authority: leases stay in `MCPControllerContext`, and every value is a
/// presentation hint (which display identity the agent has already seen, which snapshot it last
/// read) or a one-time note waiting for the next tool result. All collections are bounded, so a
/// long-lived connection that touches many sessions cannot grow this without limit.
final class MCPConnectionMemory: @unchecked Sendable {
    static let maximumSessions = 64
    static let maximumWindowsPerSession = 32
    static let maximumPendingNotes = 8
    static let maximumNoteBytes = 600

    private let lock = NSLock()
    private var displayTargets: [String: String] = [:]
    private var snapshots: [String: [UInt32: String]] = [:]
    private var pendingNotes: [String] = []
    private var driftWarning: String?
    private var driftWarningDelivered = false

    /// Connection-wide verbose receipts (`SPACEO_MCP_VERBOSE=1`).
    let verbose: Bool

    init(verbose: Bool? = nil) {
        self.verbose = verbose ?? (ProcessInfo.processInfo.environment["SPACEO_MCP_VERBOSE"] == "1")
    }

    // MARK: Display target

    /// Record the display target a response carried and say whether it differs from the last one
    /// this connection rendered for that session. The first sighting is recorded silently: an
    /// agent has nothing to compare it with, so printing it only costs tokens.
    func displayTargetChanged(session: String, target: DisplayTargetReceipt) -> Bool {
        let fingerprint = "\(target.identity.uuidString)|\(target.topologyGeneration)"
        lock.lock()
        defer { lock.unlock() }
        let previous = displayTargets[session]
        if previous == nil, displayTargets.count >= Self.maximumSessions,
           let evicted = displayTargets.keys.sorted().first {
            displayTargets.removeValue(forKey: evicted)
        }
        displayTargets[session] = fingerprint
        return previous != nil && previous != fingerprint
    }

    // MARK: Snapshots

    /// Remember the newest snapshot id this connection saw for one session window, the base an
    /// action's `observe: diff` read compares against.
    func recordSnapshot(session: String, windowID: UInt32, snapshotID: String) {
        guard !snapshotID.isEmpty, snapshotID.utf8.count <= 128 else { return }
        lock.lock()
        defer { lock.unlock() }
        if snapshots[session] == nil, snapshots.count >= Self.maximumSessions,
           let evicted = snapshots.keys.sorted().first {
            snapshots.removeValue(forKey: evicted)
        }
        var windows = snapshots[session] ?? [:]
        if windows[windowID] == nil, windows.count >= Self.maximumWindowsPerSession,
           let evicted = windows.keys.sorted().first {
            windows.removeValue(forKey: evicted)
        }
        windows[windowID] = snapshotID
        snapshots[session] = windows
    }

    func snapshot(session: String, windowID: UInt32) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return snapshots[session]?[windowID]
    }

    /// Drop everything remembered about a session that ended or was released.
    func forget(session: String) {
        lock.lock()
        defer { lock.unlock() }
        displayTargets.removeValue(forKey: session)
        snapshots.removeValue(forKey: session)
    }

    func forgetAllSessions() {
        lock.lock()
        defer { lock.unlock() }
        displayTargets.removeAll()
        snapshots.removeAll()
    }

    // MARK: One-time notes

    /// Queue a line for the start of the next tool result. Duplicates collapse; the queue is
    /// bounded and keeps the oldest notes, which name the earliest ended sessions.
    func queueNote(_ note: String) {
        let bounded = MCPDiagnostic.preview(note, maximumBytes: Self.maximumNoteBytes)
        lock.lock()
        defer { lock.unlock() }
        guard !pendingNotes.contains(bounded), pendingNotes.count < Self.maximumPendingNotes else { return }
        pendingNotes.append(bounded)
    }

    /// Set once from daemon provenance. The warning is delivered on the next tool result only.
    func setDaemonDrift(_ warning: String?) {
        lock.lock()
        defer { lock.unlock() }
        if warning != driftWarning { driftWarningDelivered = false }
        driftWarning = warning
    }

    /// The explanation for a `daemon_outdated` rewrite, when this connection saw drift.
    var daemonDrift: String? {
        lock.lock()
        defer { lock.unlock() }
        return driftWarning
    }

    /// Everything queued for the next tool result, cleared as it is returned.
    func drainNotes() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var notes: [String] = []
        if let driftWarning, !driftWarningDelivered {
            notes.append("WARNING: " + driftWarning)
            driftWarningDelivered = true
        }
        notes += pendingNotes
        pendingNotes.removeAll()
        return notes
    }
}
