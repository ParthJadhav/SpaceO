import AppKit
import Foundation

/// Hands activation back to the person when an agent application takes it (#53).
///
/// SpaceO never activates an agent application, but an application can activate itself:
/// Chromium does when a page opens a popup window, which also pulls the person onto the agent
/// display's Space and sends their keystrokes to the agent's browser until they notice. The
/// guard follows public activation notifications, remembers the person's most recent
/// application, and when an agent-owned process takes over, re-activates that application with
/// public `NSRunningApplication.activate()` — the recovery teardown already uses. It never calls a
/// private focus API, warps the pointer or changes a Space directly.
///
/// A session whose operator has control is left alone: the person chose to work there. A process
/// that keeps re-taking activation stops being restored, so the ordinary breach handling reports
/// it instead of two applications trading the front indefinitely.
public final class AgentFocusGuard: @unchecked Sendable {
    public static let shared = AgentFocusGuard()

    public enum Outcome: Equatable, Sendable {
        /// No agent application is frontmost.
        case notNeeded
        /// `app` is frontmost again after the agent process `agentPID` (`agentName`) took over.
        case restored(app: String, agentPID: pid_t, agentName: String)
        /// Restoration was not attempted or not confirmed.
        case unavailable(String)
    }

    struct Application: Equatable, Sendable {
        let pid: pid_t
        let name: String
    }

    struct Environment: Sendable {
        var frontmost: @Sendable () -> Application?
        var application: @Sendable (pid_t) -> Application?
        var activate: @Sendable (pid_t) -> Bool
        var isAgent: @Sendable (pid_t) -> Bool
        var isOperatorControlled: @Sendable (pid_t) -> Bool
        var uptime: @Sendable () -> TimeInterval
        var sleep: @Sendable (TimeInterval) -> Void

        static let live = Environment(
            frontmost: { NSWorkspace.shared.frontmostApplication.map(Application.init) },
            application: { NSRunningApplication(processIdentifier: $0).map(Application.init) },
            activate: { NSRunningApplication(processIdentifier: $0)?.activate() ?? false },
            isAgent: { AgentActivity.ownedPIDs.contains($0) },
            isOperatorControlled: { pid in
                ProcessOwnership.ownerOfPID(pid).map(AgentActivity.isUnderOperatorControl) ?? false
            },
            uptime: { ProcessInfo.processInfo.systemUptime },
            sleep: { Thread.sleep(forTimeInterval: $0) })
    }

    /// At most this many restorations per agent process within `restoreWindow` seconds.
    static let maximumRestores = 3
    static let restoreWindow: TimeInterval = 10

    private let environment: Environment
    private let lock = NSLock()
    /// Serializes restoration so a notification and an action's repair cannot both activate.
    private let restoreLock = NSLock()
    private var lastUser: Application?
    private var recentRestores: [pid_t: [TimeInterval]] = [:]
    private var observer: NSObjectProtocol?
    private var onBackgroundRestore: (@Sendable (Outcome) -> Void)?
    private let worker = DispatchQueue(label: "spaceo.agent-focus-guard")

    init(environment: Environment = .live) {
        self.environment = environment
    }

    /// Follow activation for the life of the daemon. Notifications arrive on the main run loop;
    /// observing them also keeps `NSWorkspace.frontmostApplication` current in this process.
    public func start(onBackgroundRestore: @escaping @Sendable (Outcome) -> Void) {
        start(observingWorkspace: true, onBackgroundRestore: onBackgroundRestore)
    }

    /// Tests drive `noteActivation` themselves instead of following the real workspace.
    func start(observingWorkspace: Bool, onBackgroundRestore: @escaping @Sendable (Outcome) -> Void) {
        lock.withLock {
            guard observer == nil, self.onBackgroundRestore == nil else { return }
            self.onBackgroundRestore = onBackgroundRestore
            if let front = environment.frontmost(), !environment.isAgent(front.pid) { lastUser = front }
            guard observingWorkspace else { return }
            observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
            ) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
                self?.noteActivation(Application(app))
            }
        }
    }

    public func stop() {
        lock.withLock {
            if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
            observer = nil
            onBackgroundRestore = nil
        }
    }

    /// Remember the person's application, or start returning activation to it. Never blocks
    /// the notification's thread.
    func noteActivation(_ app: Application) {
        guard environment.isAgent(app.pid) else {
            lock.withLock { lastUser = app }
            return
        }
        worker.async { [weak self] in
            guard let self else { return }
            let outcome = self.restoreIfAgentFront()
            guard outcome != .notNeeded else { return }
            let report = self.lock.withLock { self.onBackgroundRestore }
            report?(outcome)
        }
    }

    /// Return activation to the person's application if an agent process is frontmost.
    ///
    /// `preferring` names the application that was frontmost before an agent action; otherwise
    /// the most recent non-agent application is used. Success means that application is read
    /// back as frontmost within `timeout`; anything else is reported as unavailable.
    public func restoreIfAgentFront(preferring preferred: pid_t? = nil,
                                    timeout: TimeInterval = 1) -> Outcome {
        restoreLock.lock()
        defer { restoreLock.unlock() }
        guard let front = environment.frontmost(), environment.isAgent(front.pid) else { return .notNeeded }
        guard !environment.isOperatorControlled(front.pid) else {
            return .unavailable("the operator has control of \(front.name)")
        }
        let preferredApp = preferred.flatMap { pid in
            environment.isAgent(pid) ? nil : environment.application(pid)
        }
        guard let target = preferredApp ?? lock.withLock({ lastUser }) else {
            return .unavailable("no earlier application of yours is known")
        }
        let now = environment.uptime()
        let admitted = lock.withLock { () -> Bool in
            let recent = (recentRestores[front.pid] ?? []).filter { now - $0 < Self.restoreWindow }
            guard recent.count < Self.maximumRestores else {
                recentRestores[front.pid] = recent
                return false
            }
            recentRestores[front.pid] = recent + [now]
            recentRestores = recentRestores.filter { !$0.value.isEmpty }
            return true
        }
        guard admitted else {
            return .unavailable("\(front.name) keeps taking activation; SpaceO stopped returning it")
        }
        guard environment.activate(target.pid) else {
            return .unavailable("\(target.name) could not be activated")
        }
        let deadline = now + max(0, min(timeout, 2))
        repeat {
            if environment.frontmost()?.pid == target.pid {
                AgentActivity.recordFocusRestore()
                return .restored(app: target.name, agentPID: front.pid, agentName: front.name)
            }
            environment.sleep(0.01)
        } while environment.uptime() < deadline
        return .unavailable("\(target.name) was not frontmost again within \(Int(timeout * 1_000)) ms")
    }
}

extension AgentFocusGuard.Application {
    init(_ app: NSRunningApplication) {
        self.init(pid: app.processIdentifier,
                  name: app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)")
    }
}
