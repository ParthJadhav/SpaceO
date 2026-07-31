import Foundation
import AppKit
import CoreGraphics
import SpaceOPrivate

/// Owns every live session and executes commands against them.
///
/// An actor because sessions touch the WindowServer and AX, and interleaving two agents'
/// window moves would produce exactly the kind of flakiness that is miserable to debug.
public actor SessionManager {

    typealias SessionFactory =
        @Sendable (_ id: String, _ slot: DisplayPool.Slot) throws -> AgentSession
    typealias MaterializedAppHandler = (_ app: LaunchedApp) throws -> Void

    protocol SessionLaunching {
        nonisolated(nonsending) func launch(
            session: AgentSession,
            appURL: URL,
            files: [URL],
            onMaterialized: MaterializedAppHandler
        ) async throws -> LaunchedApp
    }

    private struct LiveSessionLauncher: SessionLaunching {
        nonisolated(nonsending) func launch(
            session: AgentSession,
            appURL: URL,
            files: [URL],
            onMaterialized: MaterializedAppHandler
        ) async throws -> LaunchedApp {
            try await session.launch(
                app: appURL,
                opening: files,
                onMaterialized: onMaterialized)
        }
    }

    private var sessions: [String: AgentSession] = [:]
    private var counter = 0
    private let pool: DisplayPool
    private let sessionFactory: SessionFactory
    private let sessionLauncher: any SessionLaunching
    private let daemonInstanceID: UUID
    private let reclamationPolicy: SessionReclamationPolicy
    private let successfulMutationHook: @Sendable () -> Void
    private let livePersistence: LiveSessionPersistence?
    private let recoveryCoordinator: SessionRecoveryCoordinator?
    /// Actor isolation does not serialize across `await`; this gate deliberately does. It is
    /// process-wide rather than per-session because display allocation, user input routing, and
    /// shutdown all mutate shared host resources, so ordering only same-session commands would
    /// still allow cross-session lifecycle races.
    private let operationGate: SessionOperationGate
    private var isShuttingDown = false
    private var idleDisplayRetirement: Task<Void, Never>?
    private let idleDisplayGraceNanoseconds: UInt64 = 15_000_000_000
    private var displayLifecycleFailures: Set<CGDirectDisplayID> = []
    private var janitor: Task<Void, Never>?
    private let janitorIntervalNanoseconds: UInt64 = 3_000_000_000

    public init(pool: DisplayPool = DisplayPool(), runJanitor: Bool = true) {
        self.pool = pool
        self.sessionFactory = { AgentSession(id: $0, slot: $1) }
        self.sessionLauncher = LiveSessionLauncher()
        self.operationGate = SessionOperationGate()
        self.daemonInstanceID = UUID()
        self.reclamationPolicy = SessionReclamationPolicy()
        self.successfulMutationHook = {}
        self.livePersistence = nil
        self.recoveryCoordinator = nil
        guard runJanitor else { return }
        Task { [weak self] in await self?.startJanitor() }
    }

    /// Build a manager whose successful live-session mutations are backed by durable state.
    ///
    /// The store is loaded before the manager begins accepting work. The required coordinator
    /// must have completed `startup()` first, so every prior-daemon record is already fenced.
    /// Corrupt or unreadable state fails construction instead of being treated as empty.
    public init(
        pool: DisplayPool = DisplayPool(),
        runJanitor: Bool = true,
        sessionStore: SessionStore,
        recoveryCoordinator: SessionRecoveryCoordinator,
        daemonInstanceID: UUID = UUID()
    ) throws {
        try recoveryCoordinator.assertReady(
            for: daemonInstanceID,
            store: sessionStore)
        let persistence = LiveSessionPersistence(store: sessionStore)
        let ledger = try persistence.load()
        self.pool = pool
        self.sessionFactory = { AgentSession(id: $0, slot: $1) }
        self.sessionLauncher = LiveSessionLauncher()
        self.operationGate = SessionOperationGate()
        self.daemonInstanceID = daemonInstanceID
        self.reclamationPolicy = SessionReclamationPolicy()
        self.successfulMutationHook = {}
        self.livePersistence = persistence
        self.recoveryCoordinator = recoveryCoordinator
        self.counter = max(0, (ledger?.nextAutomaticSessionNumber ?? 1) - 1)
        guard runJanitor else { return }
        Task { [weak self] in await self?.startJanitor() }
    }

    init(
        pool: DisplayPool,
        runJanitor: Bool,
        operationGate: SessionOperationGate = SessionOperationGate(),
        daemonInstanceID: UUID = UUID(),
        reclamationPolicy: SessionReclamationPolicy = SessionReclamationPolicy(),
        successfulMutationHook: @escaping @Sendable () -> Void = {},
        sessionLauncher: any SessionLaunching = LiveSessionLauncher(),
        sessionFactory: @escaping SessionFactory
    ) {
        self.pool = pool
        self.sessionFactory = sessionFactory
        self.sessionLauncher = sessionLauncher
        self.operationGate = operationGate
        self.daemonInstanceID = daemonInstanceID
        self.reclamationPolicy = reclamationPolicy
        self.successfulMutationHook = successfulMutationHook
        self.livePersistence = nil
        self.recoveryCoordinator = nil
        guard runJanitor else { return }
        Task { [weak self] in await self?.startJanitor() }
    }

    /// Persistence-enabled test construction with the same injectable runtime seams as the
    /// in-memory manager.
    init(
        pool: DisplayPool,
        runJanitor: Bool,
        operationGate: SessionOperationGate = SessionOperationGate(),
        daemonInstanceID: UUID = UUID(),
        reclamationPolicy: SessionReclamationPolicy = SessionReclamationPolicy(),
        successfulMutationHook: @escaping @Sendable () -> Void = {},
        livePersistence: LiveSessionPersistence,
        recoveryCoordinator: SessionRecoveryCoordinator? = nil,
        sessionLauncher: any SessionLaunching = LiveSessionLauncher(),
        sessionFactory: @escaping SessionFactory
    ) throws {
        let ledger = try livePersistence.load()
        self.pool = pool
        self.sessionFactory = sessionFactory
        self.sessionLauncher = sessionLauncher
        self.operationGate = operationGate
        self.daemonInstanceID = daemonInstanceID
        self.reclamationPolicy = reclamationPolicy
        self.successfulMutationHook = successfulMutationHook
        self.livePersistence = livePersistence
        self.recoveryCoordinator = recoveryCoordinator
        self.counter = max(0, (ledger?.nextAutomaticSessionNumber ?? 1) - 1)
        guard runJanitor else { return }
        Task { [weak self] in await self?.startJanitor() }
    }

    // MARK: - Janitor

    /// The runtime janitor the architecture always promised.
    ///
    /// Per-app `WindowWatcher`s handle containment; this loop covers what they structurally
    /// cannot — an app that exited (nothing left to notify us), and a session whose watchers
    /// all failed to register. It is bounded (one pass per interval, no concurrency) and
    /// cancellable, so daemon shutdown leaves no task behind.
    private func startJanitor() {
        janitor?.cancel()
        let interval = janitorIntervalNanoseconds
        janitor = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    return
                }
                guard let self else { return }
                _ = try? await self.runJanitorPass()
            }
        }
    }

    /// One pass over every session. Exposed so a test can drive the janitor deterministically
    /// instead of sleeping on a timer.
    @discardableResult
    public func runJanitorPass() async throws -> Int {
        let commandLease = try await operationGate.enter()
        defer { commandLease.finish() }
        guard !isShuttingDown else { return 0 }
        return try runJanitorPassNow()
    }

    private func runJanitorPassNow() throws -> Int {
        var reapedApps = 0
        // Detached records have no WindowServer authority. Their separate recovery engine only
        // reasons about exact process identities and is serialized with every live ledger write.
        _ = try recoveryCoordinator?.runRecoveryPass()
        for id in sessions.keys.sorted() {
            guard let session = sessions[id] else { continue }
            try persistSession(
                session,
                operationState: session.teardownPending ? .cleanupPending : .ready)
            if session.controllerSnapshot()?.reclaimable == true {
                // This is resource reclamation, not controller takeover. The existing teardown
                // path quits only SpaceO-launched apps and evacuates/releases adopted apps.
                _ = try destroyNow(id, quitApps: true)
                continue
            }
            do {
                let lifecycleLease = try session.beginOperation()
                defer { lifecycleLease.finish() }
                let reaped = session.runJanitorPass()
                reapedApps += reaped
                if reaped > 0 {
                    try persistSession(session, operationState: .ready)
                }
            } catch {
                if session.teardownPending {
                    try persistSession(session, operationState: .cleanupPending)
                    continue
                }
                throw error
            }
        }
        return reapedApps
    }

    public func stopJanitor() {
        janitor?.cancel()
        janitor = nil
    }

    var janitorIsRunning: Bool { janitor != nil }

    public var isEmpty: Bool { sessions.isEmpty }
    public var count: Int { sessions.count }
    public var displayCount: Int { pool.displayCount }
    public var sessionsPerDisplay: Int { pool.sessionsPerDisplay }

    public func setSessionsPerDisplay(_ value: Int) throws {
        try pool.setSessionsPerDisplay(value)
    }

    public func poolReport() -> [DisplayPool.DisplayReport] { pool.report() }

    // MARK: - Lifecycle

    @discardableResult
    public func create(name: String?) async throws -> AgentSession {
        let commandLease = try await operationGate.enter()
        defer { commandLease.finish() }
        guard !isShuttingDown else {
            throw SpaceOError.badRequest("the daemon is shutting down")
        }
        return try createNow(
            name: name,
            controllerOwner: nil,
            controllerLeaseID: nil,
            controllerTTLSeconds: nil)
    }

    private func createNow(
        name: String?,
        controllerOwner: DurableSessionOwner?,
        controllerLeaseID: UUID?,
        controllerTTLSeconds: TimeInterval?
    ) throws -> AgentSession {
        let latestLedger = try livePersistence?.load()
        let durableSessionIDs = Set(latestLedger?.sessions.map(\.id) ?? [])
        let namedID: String?
        if let name {
            let trimmed = try Self.canonicalSessionID(name)
            guard sessions[trimmed] == nil, !durableSessionIDs.contains(trimmed) else {
                throw SpaceOError.badRequest("session '\(trimmed)' already exists")
            }
            namedID = trimmed
        } else {
            namedID = nil
        }
        var nextCounter: Int?
        let id: String
        if let namedID {
            id = namedID
        } else {
            var candidateNumber = max(
                counter,
                (latestLedger?.nextAutomaticSessionNumber ?? 1) - 1)
            var candidateID: String
            repeat {
                guard candidateNumber < Int.max else {
                    throw SpaceOError.badRequest("automatic session id space is exhausted")
                }
                candidateNumber += 1
                candidateID = "agent-\(candidateNumber)"
            } while sessions[candidateID] != nil
                || durableSessionIDs.contains(candidateID)
            guard candidateNumber < Int.max else {
                throw SpaceOError.badRequest("automatic session id space is exhausted")
            }
            id = candidateID
            nextCounter = candidateNumber
        }
        let allowsLeaseOmission = controllerOwner == nil
        let owner = try validatedControllerOwner(controllerOwner, sessionID: id)
        let duration = try reclamationPolicy.duration(requested: controllerTTLSeconds)
        // The pool reuses a display that still has a free tile, and only builds a new one
        // when they are all full.
        let slot = try pool.allocate()
        let session: AgentSession
        do {
            session = try sessionFactory(id, slot)
        } catch {
            _ = pool.release(slot)
            throw error
        }
        session.configureController(
            owner: owner,
            daemonInstanceID: daemonInstanceID,
            leaseID: controllerLeaseID ?? UUID(),
            duration: duration,
            policy: reclamationPolicy,
            allowsLeaseOmission: allowsLeaseOmission)
        sessions[id] = session
        do {
            try persistSession(
                session,
                operationState: .ready,
                nextAutomaticSessionNumberAtLeast: (nextCounter ?? counter) + 1,
                requireNewRecord: true)
        } catch {
            // The new session was never reported as durable. Reclaim everything that can be
            // reclaimed locally, but retain an incomplete teardown in memory for retry.
            let report = session.destroy(quitApps: true)
            if report.isComplete {
                _ = pool.release(session.slot, retainEmpty: true)
                sessions.removeValue(forKey: id)
                scheduleIdleDisplayRetirement()
            }
            throw error
        }
        if let nextCounter { counter = nextCounter }
        return session
    }

    private func validatedControllerOwner(
        _ requested: DurableSessionOwner?,
        sessionID: String
    ) throws -> DurableSessionOwner {
        let owner = requested ?? DurableSessionOwner(
            id: "legacy-\(sessionID)",
            kind: .other,
            label: "legacy local controller",
            processIdentity: ProcessIdentity.current(of: getpid()))
        let id = owner.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = owner.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id == owner.id,
              !label.isEmpty, label == owner.label,
              id.utf8.count <= 256, label.utf8.count <= 256,
              id.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }),
              label.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw SpaceOError.badRequest(
                "controller owner id and label must be trimmed, non-empty, "
                    + "control-free, and at most 256 UTF-8 bytes")
        }
        return owner
    }

    static func canonicalSessionID(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, name.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }),
              !trimmed.contains("/"), !trimmed.contains("\\") else {
            throw SpaceOError.badRequest(
                "session id must not be empty or contain control characters "
                + "or path separators")
        }
        return trimmed
    }

    public func session(_ id: String) throws -> AgentSession {
        let canonical = try Self.canonicalSessionID(id)
        guard let session = sessions[canonical] else {
            throw SpaceOError.unknownSession(canonical)
        }
        return session
    }

    /// The session to act on when the caller did not name one — valid only when exactly
    /// one exists, so a multi-agent setup can never be ambiguous by accident.
    public func resolve(_ id: String?) throws -> AgentSession {
        if let id { return try session(id) }
        guard sessions.count == 1, let only = sessions.values.first else {
            throw SpaceOError.badRequest(
                sessions.isEmpty
                ? "no sessions — create one with `spaceo session create`"
                : "\(sessions.count) sessions exist; name one explicitly")
        }
        return only
    }

    private func resolveForMutation(
        _ id: String?,
        leaseID: UUID?
    ) throws -> AgentSession {
        let session = try resolve(id)
        do {
            try session.authorizeControllerMutation(leaseID: leaseID)
        } catch {
            // Authorization refreshes expiry/liveness state. If that abandoned the session, the
            // rejection itself must not leave the durable record claiming it is still owned.
            try persistSession(
                session,
                operationState: session.teardownPending ? .cleanupPending : .ready)
            throw error
        }
        return session
    }

    private func renewAfterSuccessfulMutation(
        _ session: AgentSession,
        leaseID: UUID?
    ) throws {
        successfulMutationHook()
        try session.recordSuccessfulControllerMutation(leaseID: leaseID)
        try persistSession(
            session,
            operationState: session.teardownPending ? .cleanupPending : .ready)
    }

    // MARK: - Durable live-session state

    private func persistSession(
        _ session: AgentSession,
        operationState: DurableSessionOperationState,
        cleanupComplete: Bool = false,
        cleanupDisposition: DurableSessionCleanupDisposition = .terminateLaunchedApps,
        nextAutomaticSessionNumberAtLeast requestedNextNumber: Int? = nil,
        requireNewRecord: Bool = false
    ) throws {
        guard let livePersistence else { return }
        let timestamp = max(reclamationPolicy.now(), session.createdAt)
        let minimumNextNumber = requestedNextNumber ?? max(1, counter + 1)
        try livePersistence.update(
            writerDaemonInstanceID: daemonInstanceID,
            at: timestamp,
            nextAutomaticSessionNumberAtLeast: minimumNextNumber
        ) { ledger in
            let index = ledger.sessions.firstIndex(where: { $0.id == session.id })
            let existing = index.map { ledger.sessions[$0] }
            if requireNewRecord, existing != nil {
                throw SpaceOError.badRequest(
                    "session '\(session.id)' already exists in durable state")
            }
            let record = try self.durableRecord(
                for: session,
                replacing: existing,
                operationState: operationState,
                cleanupComplete: cleanupComplete,
                cleanupDisposition: cleanupDisposition,
                at: timestamp)
            if let index {
                ledger.sessions[index] = record
            } else {
                ledger.sessions.append(record)
            }
            ledger.sessions.sort { $0.id < $1.id }
        }
    }

    private func durableRecord(
        for session: AgentSession,
        replacing existing: DurableSessionRecord?,
        operationState: DurableSessionOperationState,
        cleanupComplete: Bool,
        cleanupDisposition: DurableSessionCleanupDisposition,
        at timestamp: Date
    ) throws -> DurableSessionRecord {
        guard let controller = session.controllerSnapshot() else {
            throw SessionStoreError.invalidLedger(
                "live session '\(session.id)' has no controller lease")
        }
        let revision: UInt64
        if let existing {
            guard existing.revision < UInt64.max else {
                throw LiveSessionPersistenceError.recordRevisionExhausted(session.id)
            }
            revision = existing.revision + 1
        } else {
            revision = 1
        }

        let abandonedAt: Date?
        let reclaimableAfter: Date?
        if cleanupComplete {
            let boundary = existing?.abandonedAt ?? controller.abandonedAt ?? timestamp
            abandonedAt = boundary
            reclaimableAfter = existing?.reclaimableAfter
                ?? boundary.addingTimeInterval(reclamationPolicy.gracePeriod)
        } else {
            abandonedAt = controller.abandonedAt
            reclaimableAfter = controller.abandonedAt.map {
                $0.addingTimeInterval(reclamationPolicy.gracePeriod)
            }
        }

        let durableApps: [DurableSessionApp]
        if cleanupComplete {
            durableApps = []
        } else {
            durableApps = session.apps
                .map { app in
                    DurableSessionApp(
                        identity: app.identity,
                        provenance: app.startedByUs ? .launched : .adopted,
                        bundleIdentifier: app.bundleIdentifier,
                        name: app.name,
                        url: app.url,
                        devToolsPort: app.devToolsPort,
                        temporaryProfile: app.temporaryProfile)
                }
                .sorted {
                    if $0.identity.pid != $1.identity.pid {
                        return $0.identity.pid < $1.identity.pid
                    }
                    return $0.name < $1.name
                }
        }

        let placement = DurableSessionPlacement(
            displayID: session.stage.displayID,
            x: Double(session.frame.origin.x),
            y: Double(session.frame.origin.y),
            width: Double(session.frame.width),
            height: Double(session.frame.height),
            tileIndex: session.slot.index,
            tileCapacity: session.slot.capacity,
            exclusiveDisplay: session.hasExclusiveDisplay)
        return DurableSessionRecord(
            id: session.id,
            revision: revision,
            createdAt: existing?.createdAt ?? session.createdAt,
            updatedAt: max(
                timestamp,
                existing?.updatedAt ?? existing?.createdAt ?? session.createdAt),
            ownershipState: abandonedAt == nil ? .owned : .abandoned,
            runtimeState: cleanupComplete ? .detached : .attached,
            operationState: operationState,
            recoveryState: cleanupComplete
                ? .notNeeded
                : (controller.reclaimable ? .reclaimable : .notNeeded),
            recoveryBlockers: [],
            abandonedAt: abandonedAt,
            reclaimableAfter: reclaimableAfter,
            lastActivityAt: controller.lastActivityAt,
            owner: controller.owner,
            lease: controller.lease,
            lastKnownPlacement: placement,
            apps: durableApps,
            cleanupDisposition: cleanupDisposition)
    }

    private func pruneDurableSession(_ id: String) throws {
        guard let livePersistence else { return }
        try livePersistence.update(
            writerDaemonInstanceID: daemonInstanceID,
            at: reclamationPolicy.now(),
            nextAutomaticSessionNumberAtLeast: max(1, counter + 1)
        ) { ledger in
            guard let index = ledger.sessions.firstIndex(where: { $0.id == id }) else {
                return
            }
            guard ledger.sessions[index].operationState == .cleanupComplete else {
                throw SessionStoreError.invalidLedger(
                    "session '\(id)' cannot be pruned before cleanup completes")
            }
            ledger.sessions.remove(at: index)
        }
    }

    /// Record a newly materialized process identity before any later response work. If that first
    /// post-effect write fails, undo the registration where possible; otherwise retain in-memory
    /// ownership and retry the pending record once so restart cleanup has the exact identity.
    private func recordPostEffectOrRollback(
        session: AgentSession,
        app: LaunchedApp
    ) throws {
        try DurablePostEffectReconciliation.run(
            commitPendingIdentity: {
                try self.persistSession(session, operationState: .mutationPending)
            },
            rollbackEffect: {
                session.rollbackUndurableApp(app)
            },
            clearPreparedMarker: {
                try self.persistSession(session, operationState: .ready)
            })
    }

    /// A prior daemon's exact process ledger remains exclusive during restart grace. Otherwise a
    /// new session could adopt that process and the detached janitor would later terminate it
    /// under its original launched provenance.
    private func ensureNotReservedForDetachedRecovery(pid: pid_t) throws {
        guard let recoveryCoordinator,
              let current = ProcessIdentity.current(of: pid) else {
            return
        }
        for record in try recoveryCoordinator.detachedRecords() {
            guard let reserved = record.apps.first(where: {
                $0.identity.pid == pid
                    && (!$0.identity.isPrecise
                        || !current.isPrecise
                        || $0.identity == current)
            }) else {
                continue
            }
            let ownership = reserved.provenance == .launched
                ? "launched"
                : "adopted"
            throw SpaceOError.badRequest(
                "process \(current) remains reserved by detached session "
                    + "'\(record.id)' as a \(ownership) app; wait for its recovery grace "
                    + "or retry `spaceo session destroy --session \(record.id)`")
        }
    }

    private static func detachedRecoveryGuidance(
        records: [DurableSessionRecord]
    ) -> String {
        var lines = [
            "detached session cleanup is not complete; no persisted display or window handle "
                + "was reused."
        ]
        for record in records.sorted(by: { $0.id < $1.id }) {
            var detail = "  \(record.id): \(record.recoveryState.rawValue)"
            if let boundary = record.reclaimableAfter {
                detail += ", grace ends \(boundary.ISO8601Format())"
            }
            lines.append(detail)
            for blocker in record.recoveryBlockers {
                lines.append("    - \(blocker.code): \(blocker.message)")
            }
        }
        lines.append(
            "Wait for the recorded grace boundary, then retry the named destroy command. "
                + "SpaceO will terminate only exact launched process identities; adopted apps "
                + "are released without termination.")
        return lines.joined(separator: "\n")
    }

    public func destroy(_ id: String, quitApps: Bool) async throws -> TeardownReport {
        let commandLease = try await operationGate.enter()
        defer { commandLease.finish() }
        let report = try destroyNow(id, quitApps: quitApps)
        guard report.isComplete else {
            throw SpaceOError.teardownIncomplete(report)
        }
        return report
    }

    private func destroyNow(_ id: String, quitApps: Bool) throws -> TeardownReport {
        let canonical = try Self.canonicalSessionID(id)
        guard let session = sessions[canonical] else {
            throw SpaceOError.unknownSession(canonical)
        }
        // Persist intent before signalling or evacuating any process. A crash after this point is
        // recoverable as cleanup work, never mistaken for a ready attached session.
        let cleanupDisposition: DurableSessionCleanupDisposition = quitApps
            ? .terminateLaunchedApps
            : .releaseApps
        try persistSession(
            session,
            operationState: .cleanupPending,
            cleanupDisposition: cleanupDisposition)
        var report = session.destroy(quitApps: quitApps)
        guard report.isComplete else {
            report.stillAttachedDisplayIDs = Array(
                Set(report.stillAttachedDisplayIDs + [session.stage.displayID])
            ).sorted()
            try persistSession(
                session,
                operationState: .cleanupPending,
                cleanupDisposition: cleanupDisposition)
            return report
        }

        // Commit proof of an empty app ledger before releasing the manager's live ownership.
        // Pruning is a distinct later atomic replacement so a failed prune leaves a safe
        // cleanup-complete tombstone for restart.
        try persistSession(
            session,
            operationState: .cleanupComplete,
            cleanupComplete: true,
            cleanupDisposition: cleanupDisposition)
        _ = pool.release(session.slot, retainEmpty: true)
        sessions.removeValue(forKey: canonical)
        scheduleIdleDisplayRetirement()
        try pruneDurableSession(canonical)
        return report
    }

    @discardableResult
    public func destroyAll(quitApps: Bool) async throws -> TeardownReport {
        let commandLease = try await operationGate.enter()
        defer { commandLease.finish() }
        return try destroyAllNow(quitApps: quitApps)
    }

    private func destroyAllNow(quitApps: Bool) throws -> TeardownReport {
        idleDisplayRetirement?.cancel()
        idleDisplayRetirement = nil
        var report = TeardownReport()
        for id in sessions.keys.sorted() {
            guard sessions[id] != nil else { continue }
            let sessionReport = try destroyNow(id, quitApps: quitApps)
            report.merge(sessionReport)
        }
        // Sessions with surviving processes still own their slots. Only empty displays may be
        // retired; direct `DisplayPool.releaseAll()` deliberately has stronger force-release
        // semantics for callers that have already destroyed their own session objects.
        let attachedDisplayIDs = pool.retireEmptyDisplays()
        report.stillAttachedDisplayIDs = Array(
            Set(report.stillAttachedDisplayIDs).union(attachedDisplayIDs)
        ).sorted()
        displayLifecycleFailures.formUnion(attachedDisplayIDs)
        return report
    }

    private func scheduleIdleDisplayRetirement() {
        idleDisplayRetirement?.cancel()
        let delay = idleDisplayGraceNanoseconds
        idleDisplayRetirement = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.retireIdleDisplays()
        }
    }

    private func retireIdleDisplays() {
        // Keep one stable warm display for the daemon's lifetime. This avoids an attach/detach
        // cycle for every short-lived MCP session while still retiring excess peak capacity.
        displayLifecycleFailures.formUnion(pool.retireEmptyDisplays(keeping: 1))
        idleDisplayRetirement = nil
    }

    /// Recorded teardown failures, pruned against the live display inventory. A teardown that
    /// timed out may still have completed later; keep reporting and refusing only while the
    /// display is genuinely attached, because claiming a detached display "remains attached"
    /// forever would be false. Every reader must come through here so they agree.
    private func liveDisplayLifecycleFailures() -> Set<CGDirectDisplayID> {
        guard !displayLifecycleFailures.isEmpty else { return [] }
        displayLifecycleFailures.formIntersection(Stage.onlineDisplayIDs())
        return displayLifecycleFailures
    }

    public func infos() async throws -> [SessionInfo] {
        let commandLease = try await operationGate.enter()
        defer { commandLease.finish() }
        return try infosNow()
    }

    private func infosNow() throws -> [SessionInfo] {
        var infos: [SessionInfo] = []
        for session in sessions.values.sorted(by: { $0.createdAt < $1.createdAt }) {
            if let lifecycleLease = try? session.beginOperation() {
                defer { lifecycleLease.finish() }
                session.refreshWindows()
            }
            let info = SessionInfo(session)
            try persistSession(
                session,
                operationState: session.teardownPending ? .cleanupPending : .ready)
            infos.append(info)
        }
        if let recoveryCoordinator {
            infos.append(contentsOf: try recoveryCoordinator.detachedRecords().map {
                SessionInfo($0)
            })
        }
        return infos.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id < $1.id
        }
    }

    // MARK: - Command dispatch

    public func handle(_ request: Request) async -> Response {
        do {
            let commandLease = try await operationGate.enter()
            defer { commandLease.finish() }
            if isShuttingDown, request.cmd != "daemon.stop" {
                throw SpaceOError.badRequest("the daemon is shutting down")
            }
            return try await execute(request)
        } catch {
            return .failure(error)
        }
    }

    private func execute(_ request: Request) async throws -> Response {
        switch request.cmd {

        case "ping":
            let failures = liveDisplayLifecycleFailures()
            let detachedCount = try recoveryCoordinator?.detachedRecords().count ?? 0
            let suffix = failures.isEmpty
                ? ""
                : ", failed display teardown: \(failures.sorted())"
            return .success(
                "spaceo daemon alive, \(sessions.count) live session(s), "
                    + "\(detachedCount) detached recovery record(s)\(suffix)")

        case "daemon.stop":
            if let recoveryCoordinator {
                let recovery = try recoveryCoordinator.runRecoveryPass()
                let detached = recovery.ledger.sessions.filter {
                    $0.runtimeState == .detached
                }
                guard detached.isEmpty else {
                    throw SpaceOError.badRequest(
                        Self.detachedRecoveryGuidance(records: detached))
                }
            }
            isShuttingDown = true
            stopJanitor()
            let report = try destroyAllNow(quitApps: true)
            guard report.isComplete else {
                throw SpaceOError.teardownIncomplete(report)
            }
            return .success("stopping SpaceO daemon")

        case "session.create":
            let session = try createNow(
                name: request.session,
                controllerOwner: request.controllerOwner,
                controllerLeaseID: request.controllerLeaseID,
                controllerTTLSeconds: request.controllerTTLSeconds)
            var response = Response(ok: true)
            response.session = SessionInfo(session)
            response.controllerLeaseID = session.controllerSnapshot()?.lease.leaseID
            response.message = session.hasExclusiveDisplay
                ? "created '\(session.id)' with exclusive display \(session.stage.displayID)"
                : "created '\(session.id)' on display \(session.stage.displayID), tile \(session.slot.index + 1)/\(session.slot.capacity)"
            return response

        case "session.list":
            var response = Response(ok: true)
            response.sessions = try infosNow()
            return response

        case "session.heartbeat":
            guard let leaseID = request.controllerLeaseID else {
                throw SpaceOError.badRequest(
                    "session.heartbeat needs controllerLeaseID")
            }
            let session = try resolveForMutation(
                request.session,
                leaseID: request.controllerLeaseID)
            _ = try session.heartbeatController(leaseID: leaseID)
            try persistSession(session, operationState: .ready)
            var response = Response(ok: true)
            response.session = SessionInfo(session)
            response.controllerLeaseID = leaseID
            response.message = "renewed controller lease for '\(session.id)'"
            return response

        case "session.destroy":
            if request.session == nil && (request.full ?? false) {
                let quitApps = request.quitApps ?? true
                if !quitApps, let recoveryCoordinator {
                    let detached = try recoveryCoordinator.detachedRecords()
                    guard detached.isEmpty else {
                        throw SpaceOError.badRequest(
                            "`--keep-apps` cannot be applied to detached recovery records; "
                                + "no prior-daemon window authority remains. Retry named "
                                + "cleanup without `--keep-apps`, or wait for automatic recovery.")
                    }
                }
                let report = try destroyAllNow(quitApps: quitApps)
                guard report.isComplete else {
                    throw SpaceOError.teardownIncomplete(report)
                }
                if let recoveryCoordinator {
                    let recovery = try recoveryCoordinator.runRecoveryPass()
                    guard recovery.ledger.sessions.allSatisfy({
                        $0.runtimeState != .detached
                    }) else {
                        throw SpaceOError.badRequest(
                            Self.detachedRecoveryGuidance(
                                records: recovery.ledger.sessions.filter {
                                    $0.runtimeState == .detached
                                }))
                    }
                }
                return .success("destroyed all sessions")
            }
            if let requestedID = request.session,
               let canonicalID = Optional(try Self.canonicalSessionID(requestedID)),
               sessions[canonicalID] == nil,
               let recoveryCoordinator {
                guard request.quitApps ?? true else {
                    throw SpaceOError.badRequest(
                        "`--keep-apps` cannot be applied to detached session "
                            + "'\(canonicalID)'; no prior-daemon window authority remains")
                }
                let result = try recoveryCoordinator.retryCleanup(sessionID: canonicalID)
                guard result.record == nil else {
                    throw SpaceOError.badRequest(
                        Self.detachedRecoveryGuidance(records: [result.record!]))
                }
                return .success("cleaned detached session '\(canonicalID)'")
            } else {
                let session = try resolveForMutation(
                    request.session,
                    leaseID: request.controllerLeaseID)
                let id = session.id
                let report = try destroyNow(id, quitApps: request.quitApps ?? true)
                guard report.isComplete else {
                    throw SpaceOError.teardownIncomplete(report)
                }
                return .success("destroyed '\(id)'")
            }

        case "run":
            guard let appName = request.app else { throw SpaceOError.badRequest("run needs an app") }
            let trimmedAppName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedAppName.isEmpty, appName.count <= 4_096,
                  appName.utf8.count <= 16_384 else {
                throw SpaceOError.badRequest(
                    "app must be 1 through 4096 characters and at most 16384 UTF-8 bytes")
            }
            let filePaths = request.files ?? []
            guard filePaths.count <= 256 else {
                throw SpaceOError.badRequest("run accepts at most 256 file paths")
            }
            guard filePaths.allSatisfy({
                $0.count <= 4_096 && $0.utf8.count <= 16_384
            }) else {
                throw SpaceOError.badRequest(
                    "every file path must be at most 4096 characters and 16384 UTF-8 bytes")
            }
            let session = try resolveForMutation(
                request.session,
                leaseID: request.controllerLeaseID)
            let lifecycleLease = try session.beginOperation()
            defer { lifecycleLease.finish() }
            guard let appURL = AppLauncher.resolve(trimmedAppName) else {
                throw SpaceOError.launchFailed(
                    "could not find an application named '\(trimmedAppName)'")
            }
            let files = filePaths.map {
                URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
            }
            // Durable prepare precedes process launch. The materialization callback below then
            // commits the exact identity before DevTools discovery or window placement waits.
            try persistSession(session, operationState: .mutationPending)
            let before = IsolationSnapshot.capture()
            let appsBeforeLaunch = Set(session.apps.map(\.identity))
            let app: LaunchedApp
            do {
                app = try await sessionLauncher.launch(
                    session: session,
                    appURL: appURL,
                    files: files,
                    onMaterialized: { materialized in
                        try self.recordPostEffectOrRollback(
                            session: session,
                            app: materialized)
                    })
            } catch {
                let mutationError = error
                _ = session.reapExitedApps()
                let hasMaterializedSurvivor = session.apps.contains {
                    !appsBeforeLaunch.contains($0.identity)
                }
                // A pre-materialization failure has no effect and may clear the prepare. Once an
                // identity was registered, keep cleanup-only state until the survivor is gone.
                try persistSession(
                    session,
                    operationState: hasMaterializedSurvivor
                        ? .mutationPending
                        : .ready)
                throw mutationError
            }
            let after = IsolationSnapshot.capture()

            var response = Response(ok: true)
            response.isolation = after.report(comparedTo: before)
            response.drift = response.isolation?.legacyDrift
            response.ambient = after.ambientChanges(from: before)
            var message = "launched \(app.name) (pid \(app.pid)) onto '\(session.id)'"
            if let restored = session.lastLaunchRestoredFocus {
                message += "\n  note: \(app.name) grabbed focus on startup; handed it back to \(restored)"
            }
            response.message = message
            failOnIsolationBreach(&response, action: "launch")
            if response.ok {
                try renewAfterSuccessfulMutation(
                    session,
                    leaseID: request.controllerLeaseID)
                response.session = SessionInfo(session)
            } else {
                // Isolation failure changes the command result, not the fact that an app was
                // launched and is now owned by this session.
                try persistSession(session, operationState: .ready)
            }
            return response

        case "adopt":
            guard let pid = request.pid, pid > 0 else {
                throw SpaceOError.badRequest("adopt needs a positive --pid")
            }
            let session = try resolveForMutation(
                request.session,
                leaseID: request.controllerLeaseID)
            try ensureNotReservedForDetachedRecovery(pid: pid)
            let lifecycleLease = try session.beginOperation()
            defer { lifecycleLease.finish() }
            try persistSession(session, operationState: .mutationPending)
            let app: LaunchedApp
            do {
                app = try session.adopt(pid: pid)
            } catch {
                let mutationError = error
                try persistSession(session, operationState: .ready)
                throw mutationError
            }
            try recordPostEffectOrRollback(session: session, app: app)
            try renewAfterSuccessfulMutation(
                session,
                leaseID: request.controllerLeaseID)
            var response = Response(ok: true)
            response.session = SessionInfo(session)
            response.message = "adopted \(app.name) (pid \(pid))"
            return response

        case "windows":
            let session = try resolve(request.session)
            let lifecycleLease = try session.beginOperation()
            defer { lifecycleLease.finish() }
            session.sweepStrayWindows()
            session.refreshWindows()
            var response = Response(ok: true)
            response.windows = session.windows.map { WindowInfo($0, session: session) }
            return response

        case "pool":
            var response = Response(ok: true)
            response.displays = pool.report()
            let usage = pool.usage()
            response.usage = usage
            response.limits = ResourceLimitsReport(pool.budget)
            response.message = Self.poolSummary(displays: pool.displayCount,
                                                sessions: pool.sessionCount,
                                                perDisplay: pool.sessionsPerDisplay,
                                                usage: usage,
                                                budget: pool.budget)
            return response

        case "pool.configure":
            guard let value = request.count else {
                throw SpaceOError.badRequest("pool.configure needs a session count")
            }
            try setSessionsPerDisplay(value)
            var response = Response(ok: true)
            response.message = "new displays will host \(value) session(s) each"
            response.displays = pool.report()
            response.usage = pool.usage()
            response.limits = ResourceLimitsReport(pool.budget)
            return response

        case "ax":
            let session = try resolve(request.session)
            let lifecycleLease = try session.beginOperation()
            defer { lifecycleLease.finish() }
            let window = try session.resolveWindow(request.window)
            let snapshot = try session.snapshotAX(window: window)
            var outline = snapshot.outline(includeNonActionable: request.full ?? false)
            var message = "\(snapshot.actionableCount) actionable element(s) in window \(window.windowID)"

            // For a browser we launched, the AX tree only covers the browser's own chrome.
            // The page itself has to come from DevTools, so append it under its own indices.
            if let bridge = session.webBridge(for: window.pid) {
                do {
                    let page = try await bridge.interactiveElements()
                    outline += "\n\npage content (click these with --element wN):\n" + page
                    message += ", plus page elements"
                } catch {
                    // Silence here would read as "the page has no elements", which is a lie.
                    outline += "\n\n(page content unavailable: \(error))"
                }
            }
            var response = Response(ok: true)
            response.outline = outline
            // A screen read that stopped short reads exactly like a complete one, so an agent
            // reasons over a partial view believing it is the whole screen. The traversal marks
            // every clipped value with an ellipsis; surface that as a flag and say so in words.
            if outline.contains("…") {
                response.truncated = true
                message += "\n  note: some values were clipped (shown with …). A long document's "
                    + "text is not readable in full through the accessibility outline; screenshot "
                    + "the window, or scroll and read again."
            }
            response.message = message
            return response

        case "click":
            let clickCount = request.count ?? 1
            guard (1...3).contains(clickCount) else {
                throw SpaceOError.badRequest("click count must be from 1 through 3")
            }
            let button = try MouseButton.parse(request.button)
            let modifiers = try ModifierKeys.parse(request.modifiers)
            if let x = request.x, !x.isFinite {
                throw SpaceOError.badRequest("x must be a finite number")
            }
            if let y = request.y, !y.isFinite {
                throw SpaceOError.badRequest("y must be a finite number")
            }
            if let element = request.element,
               element.count > 32 || element.utf8.count > 128 {
                throw SpaceOError.badRequest(
                    "element reference must be at most 32 characters and 128 UTF-8 bytes")
            }
            let session = try resolveForMutation(
                request.session,
                leaseID: request.controllerLeaseID)
            let lifecycleLease = try session.beginOperation()
            defer { lifecycleLease.finish() }
            let before = IsolationSnapshot.capture()
            let window = try session.resolveWindow(request.window)
            defer { session.invalidateAXSnapshot() }
            var clickWarnings: [String] = []

            if let reference = request.element, reference.hasPrefix("w") {
                // Page element: only DevTools can dispatch a real DOM click.
                guard let index = Int(reference.dropFirst()) else {
                    throw SpaceOError.badRequest("'\(reference)' is not a web element reference")
                }
                guard index >= 0 else {
                    throw SpaceOError.badRequest("web element indices cannot be negative")
                }
                guard modifiers.isEmpty else {
                    throw SpaceOError.badRequest(
                        "modifier-held clicks are not available on web element references; "
                        + "click the element's coordinates instead")
                }
                guard let bridge = session.webBridge(for: window.pid) else {
                    throw SpaceOError.badRequest(
                        "this session has no DevTools element map; click by native element "
                        + "or coordinates instead")
                }
                try await bridge.clickElement(index: index, button: button,
                                              clickCount: clickCount)
            } else if let reference = request.element {
                guard let index = Int(reference) else {
                    throw SpaceOError.badRequest("'\(reference)' is not an element index")
                }
                guard index >= 0 else {
                    throw SpaceOError.badRequest("element indices cannot be negative")
                }
                // An indexed press is an accessibility action, not a pointer event: it has no
                // button, no click count and no modifier state. Accepting those and performing a
                // plain press anyway reported success for an action that never happened — the
                // agent believed it had opened a context menu or extended a selection.
                guard button == .left, clickCount == 1, modifiers.isEmpty else {
                    throw SpaceOError.badRequest(
                        "an element index performs an accessibility press, which cannot carry a "
                        + "button, click count, or modifiers. Read the element's coordinates from "
                        + "a screenshot and click by --x/--y for that.")
                }
                let element = try session.element(at: index, for: window)
                try InputRouter.press(element)
            } else if let x = request.x, let y = request.y {
                if let bridge = session.webBridge(for: window.pid) {
                    // Coordinates inside a browser window belong to the page, and synthetic
                    // mouse events never arrive there. Translate into viewport space and let
                    // DevTools dispatch it.
                    guard modifiers.isEmpty else {
                        throw SpaceOError.badRequest(
                            "modifier-held clicks are not yet dispatched through DevTools; "
                            + "this browser window cannot receive them")
                    }
                    // `web` means x/y are already CSS viewport coordinates, matching what
                    // read_screen prints beside each wN element. Previously this flag was
                    // accepted here and silently ignored.
                    let page: CGPoint
                    if request.web == true {
                        page = CGPoint(x: x, y: y)
                    } else {
                        let bounds = try WindowPlacement.liveBounds(of: window.windowID)
                        page = try await bridge.viewportPoint(
                            windowLocal: CGPoint(x: x, y: y), windowOrigin: bounds.origin)
                    }
                    try await bridge.click(x: page.x, y: page.y,
                                           button: button, clickCount: clickCount)
                } else {
                    let delivery = try InputRouter.click(
                        window, at: CGPoint(x: x, y: y),
                        button: button, clickCount: clickCount,
                        modifiers: modifiers)
                    if !delivery.isConfirmed {
                        clickWarnings.append(InputRouter.unverifiedDeliveryNote("click"))
                    }
                }
            } else {
                throw SpaceOError.badRequest("click needs --element N (or wN for page elements) or --x X --y Y")
            }
            var response = Response(ok: true)
            response.warnings = clickWarnings.isEmpty ? nil : clickWarnings
            let now = IsolationSnapshot.capture()
            response.isolation = now.report(comparedTo: before)
            response.drift = response.isolation?.legacyDrift
            response.ambient = now.ambientChanges(from: before)
            failOnIsolationBreach(&response, action: "click")
            if response.ok {
                try renewAfterSuccessfulMutation(
                    session,
                    leaseID: request.controllerLeaseID)
            }
            return response

        case "scroll", "move", "drag":
            // The three pointer actions share every step except the events they post: same
            // lease, same lifecycle barrier, same window resolution, same isolation bracket.
            let modifiers = try ModifierKeys.parse(request.modifiers)
            let button = try MouseButton.parse(request.button)
            guard let x = request.x, let y = request.y else {
                throw SpaceOError.badRequest("\(request.cmd) needs --x X --y Y")
            }
            let session = try resolveForMutation(
                request.session,
                leaseID: request.controllerLeaseID)
            let lifecycleLease = try session.beginOperation()
            defer { lifecycleLease.finish() }
            let window = try session.resolveWindow(request.window)
            defer { session.invalidateAXSnapshot() }
            let before = IsolationSnapshot.capture()
            let at = CGPoint(x: x, y: y)

            // A point inside a browser window belongs to the page, and nothing synthetic reaches
            // web content — the renderer drops events the WindowServer did not vouch for, and a
            // page's scroller is not an accessibility scroll bar either. DevTools is the only
            // channel that works, exactly as it already is for clicks.
            if let bridge = session.webBridge(for: window.pid) {
                guard modifiers.isEmpty else {
                    throw SpaceOError.badRequest(
                        "modifier-held pointer actions are not yet dispatched through DevTools; "
                        + "this browser window cannot receive them")
                }
                // `web` means the caller is already speaking CSS viewport coordinates — which is
                // what `read_screen` prints next to every `wN` element. Without this an agent
                // that reads `[w0] button at (70,37)` and passes those numbers straight back
                // lands roughly a browser-chrome's height above what it aimed at.
                let page: CGPoint
                if request.web == true {
                    page = at
                } else {
                    let bounds = try WindowPlacement.liveBounds(of: window.windowID)
                    page = try await bridge.viewportPoint(
                        windowLocal: at, windowOrigin: bounds.origin)
                }
                switch request.cmd {
                case "scroll":
                    try await bridge.scroll(
                        x: page.x, y: page.y,
                        deltaX: Double(request.dx ?? 0), deltaY: Double(-(request.dy ?? 0)),
                        ticks: request.ticks ?? 1)
                case "move":
                    try await bridge.move(x: page.x, y: page.y)
                default:
                    guard let toX = request.toX, let toY = request.toY else {
                        throw SpaceOError.badRequest("drag needs --to-x X --to-y Y")
                    }
                    let destination: CGPoint
                    if request.web == true {
                        destination = CGPoint(x: toX, y: toY)
                    } else {
                        let bounds = try WindowPlacement.liveBounds(of: window.windowID)
                        destination = try await bridge.viewportPoint(
                            windowLocal: CGPoint(x: toX, y: toY), windowOrigin: bounds.origin)
                    }
                    try await bridge.drag(
                        fromX: page.x, fromY: page.y,
                        toX: destination.x, toY: destination.y, button: button)
                }
            } else {
                switch request.cmd {
                case "scroll":
                    let dy = request.dy ?? 0
                    try InputRouter.scroll(window, at: at, dx: request.dx ?? 0, dy: dy,
                                           ticks: request.ticks ?? 1, modifiers: modifiers)
                case "move":
                    try InputRouter.move(window, to: at, modifiers: modifiers)
                default:
                    guard let toX = request.toX, let toY = request.toY else {
                        throw SpaceOError.badRequest("drag needs --to-x X --to-y Y")
                    }
                    try InputRouter.drag(window, from: at, to: CGPoint(x: toX, y: toY),
                                         button: button, modifiers: modifiers)
                }
            }

            var response = Response(ok: true)
            let now = IsolationSnapshot.capture()
            response.isolation = now.report(comparedTo: before)
            response.drift = response.isolation?.legacyDrift
            response.ambient = now.ambientChanges(from: before)
            failOnIsolationBreach(&response, action: request.cmd)
            if response.ok {
                try renewAfterSuccessfulMutation(
                    session,
                    leaseID: request.controllerLeaseID)
            }
            return response

        case "type":
            guard let text = request.text else { throw SpaceOError.badRequest("type needs text") }
            guard text.count <= 8_000, text.unicodeScalars.count <= 8_000,
                  text.utf8.count <= 32_000 else {
                throw SpaceOError.badRequest(
                    "text is too long (maximum 8000 characters/scalars "
                    + "and 32000 UTF-8 bytes)")
            }
            if request.web != true { try InputRouter.validateTyping(text) }
            let session = try resolveForMutation(
                request.session,
                leaseID: request.controllerLeaseID)
            let lifecycleLease = try session.beginOperation()
            defer { lifecycleLease.finish() }
            let window = try session.resolveWindow(request.window)
            defer { session.invalidateAXSnapshot() }
            let before = IsolationSnapshot.capture()
            if request.web == true {
                if let bridge = session.webBridge(for: window.pid) {
                    try await bridge.type(text)
                } else {
                    try InputRouter.prepareForInput(window)
                    try InputRouter.type(text, to: window.pid)
                }
            } else {
                try InputRouter.prepareForInput(window)
                try InputRouter.type(text, to: window.pid)
            }
            var response = Response(ok: true)
            let now = IsolationSnapshot.capture()
            response.isolation = now.report(comparedTo: before)
            response.drift = response.isolation?.legacyDrift
            response.ambient = now.ambientChanges(from: before)
            response.value = AXTree.focusedValue(pid: window.pid)
            failOnIsolationBreach(&response, action: "typing")
            if response.ok {
                try renewAfterSuccessfulMutation(
                    session,
                    leaseID: request.controllerLeaseID)
            }
            return response

        case "key":
            guard let combo = request.key else { throw SpaceOError.badRequest("key needs a combo") }
            guard !combo.isEmpty, combo.count <= 64, combo.utf8.count <= 256 else {
                throw SpaceOError.badRequest(
                    "key combo must be 1 through 64 characters and at most 256 UTF-8 bytes")
            }
            let session = try resolveForMutation(
                request.session,
                leaseID: request.controllerLeaseID)
            let lifecycleLease = try session.beginOperation()
            defer { lifecycleLease.finish() }
            let window = try session.resolveWindow(request.window)
            defer { session.invalidateAXSnapshot() }
            // Parse once before choosing native versus DevTools delivery. In particular this
            // keeps Command-C/X recognition identical on both guarded production routes.
            let parsedCombo = try KeyCombo.parse(combo)
            let before = IsolationSnapshot.capture()
            if request.web == true {
                if let bridge = session.webBridge(for: window.pid) {
                    try await bridge.key(parsedCombo)
                } else {
                    try InputRouter.prepareForInput(window)
                    try InputRouter.key(parsedCombo, to: window.pid)
                }
            } else {
                try InputRouter.prepareForInput(window)
                try InputRouter.key(parsedCombo, to: window.pid)
            }
            var response = Response(ok: true)
            let now = IsolationSnapshot.capture()
            response.isolation = now.report(comparedTo: before)
            response.drift = response.isolation?.legacyDrift
            response.ambient = now.ambientChanges(from: before)
            failOnIsolationBreach(&response, action: "key press")
            if response.ok {
                try renewAfterSuccessfulMutation(
                    session,
                    leaseID: request.controllerLeaseID)
            }
            return response

        case "screenshot":
            if let output = request.output,
               output.count > 4_096 || output.utf8.count > 16_384 {
                throw SpaceOError.badRequest(
                    "screenshot output path must be at most 4096 characters "
                    + "and 16384 UTF-8 bytes")
            }
            let session = try resolve(request.session)
            let lifecycleLease = try session.beginOperation()
            defer { lifecycleLease.finish() }
            try Capabilities().requireCapture()
            let scale = try Capture.validatedScale(request.scale)
            // A sub-region is expressed against the session's tile, so an agent zooming into a
            // detail never needs the window's global origin to ask for it.
            var subRect: CGRect?
            if request.x != nil || request.y != nil
                || request.width != nil || request.height != nil {
                guard let x = request.x, let y = request.y,
                      let width = request.width, let height = request.height else {
                    throw SpaceOError.badRequest(
                        "a screenshot region needs x, y, width and height together")
                }
                guard x.isFinite, y.isFinite else {
                    throw SpaceOError.badRequest("region x and y must be finite numbers")
                }
                subRect = CGRect(x: x, y: y, width: Double(width), height: Double(height))
            }
            let captured: (image: CGImage, geometry: ImageGeometry)
            let label: String
            if let windowID = request.window, subRect == nil {
                let window = try session.resolveWindow(windowID)
                captured = try await Capture.window(window, scale: scale)
                label = "window \(windowID)"
            } else if subRect != nil {
                captured = try await Capture.region(
                    session.stage, session.frame, subRect: subRect, scale: scale)
                label = "region of tile on display \(session.stage.displayID)"
            } else if request.full ?? false {
                // "the whole screen" means this session's tile — never a neighbour's.
                captured = try await Capture.region(
                    session.stage, session.frame, scale: scale)
                label = session.hasExclusiveDisplay
                    ? "display \(session.stage.displayID)"
                    : "tile \(session.slot.index + 1)/\(session.slot.capacity) of display \(session.stage.displayID)"
            } else if let window = session.primaryWindow {
                captured = try await Capture.window(window, scale: scale)
                label = "window \(window.windowID)"
            } else {
                captured = try await Capture.region(
                    session.stage, session.frame, scale: scale)
                label = "tile of display \(session.stage.displayID)"
            }
            let image = captured.image
            let path = request.output
                ?? NSTemporaryDirectory() + "spaceo-\(UUID().uuidString).png"
            try Capture.write(image, to: URL(fileURLWithPath: path))
            var response = Response(ok: true)
            response.path = path
            response.image = captured.geometry
            response.message = "captured \(label) (\(image.width)x\(image.height), "
                + "rendered=\(Capture.looksRendered(image)))\n  \(captured.geometry.advice)"
            return response

        case "verify":
            let session = try resolve(request.session)
            let lifecycleLease = try session.beginOperation()
            defer { lifecycleLease.finish() }
            session.sweepStrayWindows()
            let snapshot = IsolationSnapshot.capture()
            var response = Response(ok: true)
            response.findings = session.audit()
            response.session = SessionInfo(session)
            // A point-in-time audit exposes current covered state without inventing historical
            // input-route evidence that macOS did not make observable.
            response.isolation = snapshot.currentReport()
            response.drift = response.isolation?.legacyDrift
            let auditFailures = response.findings! + (response.isolation?.failures ?? [])
            if auditFailures.isEmpty {
                response.message = response.isolation?.verdict == .partial
                    ? "session '\(session.id)' has no covered audit failures; "
                        + "isolation coverage is partial"
                    : "session '\(session.id)' passed its covered isolation audit"
            } else {
                response.message = "\(auditFailures.count) issue(s)"
            }
            if !auditFailures.isEmpty {
                response.ok = false
                response.error = "session '\(session.id)' failed its isolation audit:\n  - "
                    + auditFailures.joined(separator: "\n  - ")
            }
            return response

        case "repark":
            let session = try resolveForMutation(
                request.session,
                leaseID: request.controllerLeaseID)
            let lifecycleLease = try session.beginOperation()
            defer { lifecycleLease.finish() }
            let moved = session.reparkEscapedWindows()
            try renewAfterSuccessfulMutation(
                session,
                leaseID: request.controllerLeaseID)
            return .success("re-parked \(moved) window(s)")

        default:
            throw SpaceOError.badRequest("unknown command '\(request.cmd)'")
        }
    }

    /// The `pool` message: what is currently allocated.
    static func poolSummary(displays: Int,
                            sessions: Int,
                            perDisplay: Int,
                            usage: ResourceBudget.Usage,
                            budget: ResourceBudget) -> String {
        var lines = ["\(displays) display(s), \(sessions) session(s), \(perDisplay) per display"]
        _ = budget
        let parts = [
            "sessions \(usage.sessions)",
            "displays \(usage.displays)",
            "pixels \(usage.pixels)",
            "new displays this minute \(usage.creationsInLastMinute)",
        ]
        lines.append("  usage: " + parts.joined(separator: ", "))
        return lines.joined(separator: "\n")
    }

    private func failOnIsolationBreach(_ response: inout Response, action: String) {
        let failures = response.isolation?.failures ?? response.drift ?? []
        guard !failures.isEmpty else { return }
        response.ok = false
        response.error = "isolation breach during \(action): "
            + failures.joined(separator: "; ")
    }
}
