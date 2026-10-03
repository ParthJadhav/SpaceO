import Foundation

/// Content-free observations. A ready sample is admission evidence, not an OS safety guarantee.
public struct DisplayHostHealthReport: Codable, Sendable, Equatable {
    public var state: DisplaySafetyStatus.State
    public var reasons: [String]
    public var colorsyncCPUPercent: Double?
    public var colorsyncIdleServices: Int? = nil
    public var memoryPressure: UInt32?
    public var swapinsDelta: UInt64?
    public var swapoutsDelta: UInt64?
    public var windowServerDiagnosticReports: Int?
}

struct DisplayHostHealthSample: Sendable {
    enum Service: Sendable, Equatable {
        case running(pid: Int32, start: String, cpuSeconds: Double)
        case idle(launches: UInt64)

        init(pid: Int32, start: String, cpuSeconds: Double) {
            self = .running(pid: pid, start: start, cpuSeconds: cpuSeconds)
        }

        var cpuSeconds: Double? {
            if case let .running(_, _, value) = self { return value }
            return nil
        }
    }
    let uptime: TimeInterval
    let pressure: UInt32
    let swapins: UInt64
    let swapouts: UInt64
    let services: [String: Service]
    let diagnosticReports: Int

    static func assess(_ before: Self, _ after: Self) throws -> DisplayHostHealthReport {
        let elapsed = after.uptime - before.uptime
        guard elapsed.isFinite, (4...10).contains(elapsed),
              [1, 2, 4].contains(before.pressure), [1, 2, 4].contains(after.pressure),
              before.swapins <= after.swapins, before.swapouts <= after.swapouts,
              before.diagnosticReports >= 0, after.diagnosticReports >= 0,
              Set(before.services.keys) == Set(DisplayHostHealthSampler.services),
              Set(after.services.keys) == Set(before.services.keys) else { throw Unknown() }
        var cpu = 0.0
        var idle = 0
        for name in DisplayHostHealthSampler.services {
            guard let old = before.services[name], let new = after.services[name] else { throw Unknown() }
            switch (old, new) {
            case let (.running(oldPID, oldStart, oldCPU), .running(pid, start, newCPU)):
                guard oldPID > 0, oldPID == pid, !oldStart.isEmpty, oldStart == start,
                      oldCPU.isFinite, newCPU.isFinite, oldCPU >= 0, newCPU >= oldCPU else { throw Unknown() }
                cpu += (newCPU - oldCPU) / elapsed * 100
            case let (.idle(oldLaunches), .idle(launches)):
                guard oldLaunches == launches else { throw Unknown() }
                idle += 1
            default:
                throw Unknown()
            }
        }
        guard cpu.isFinite else { throw Unknown() }
        let swapins = after.swapins - before.swapins, swapouts = after.swapouts - before.swapouts
        let reports = max(before.diagnosticReports, after.diagnosticReports)
        var reasons: [String] = []
        if before.pressure != 1 || after.pressure != 1 { reasons.append("memory_pressure") }
        if cpu >= 50 { reasons.append("colorsync_busy") }
        if swapins > 0 || swapouts > 0 { reasons.append("swap_activity") }
        if reports > 0 { reasons.append("recent_windowserver_diagnostic") }
        return .init(state: reasons.isEmpty ? .ready : .blocked, reasons: reasons,
                     colorsyncCPUPercent: cpu, colorsyncIdleServices: idle, memoryPressure: after.pressure,
                     swapinsDelta: swapins, swapoutsDelta: swapouts,
                     windowServerDiagnosticReports: reports)
    }

    struct Unknown: Error {}
}

/// One sampler and an independent watchdog. Nothing here queries or mutates WindowServer.
/// A stuck sampler is never replaced; late results cannot clear the sticky failure.
final class DisplayHostHealth: @unchecked Sendable {
    private let lock = NSLock()
    private let worker = DispatchQueue(label: "spaceo.host-health-sampler")
    private let watchdog = DispatchQueue(label: "spaceo.host-health-watchdog")
    private var timer: DispatchSourceTimer?
    private let initialDecision = DispatchGroup()
    private var waitingForInitialDecision = true
    private var started = false
    private var inFlightSince: TimeInterval?
    private var lastAttempt: TimeInterval?
    private var previous: DisplayHostHealthSample?
    private var reportedAt: TimeInterval?
    private var current = DisplayHostHealthReport(state: .unknown, reasons: ["not_sampled"])
    private let sample: @Sendable () throws -> DisplayHostHealthSample
    private let now: @Sendable () -> TimeInterval
    private let onFailure: @Sendable (String) -> Void

    init(sample: @escaping @Sendable () throws -> DisplayHostHealthSample = { try DisplayHostHealthSampler.capture() },
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         onFailure: @escaping @Sendable (String) -> Void = { _ in }) {
        self.sample = sample
        self.now = now
        self.onFailure = onFailure
        initialDecision.enter()
    }

    var report: DisplayHostHealthReport {
        expireIfNeeded()
        return lock.withLock { current }
    }

    var hasStarted: Bool { lock.withLock { started } }

    func requireHealthy() throws {
        start()
        guard initialDecision.wait(timeout: .now() + 10) == .success else {
            fail("host_health_timeout")
            throw SpaceOError.stageCreationFailed("host health could not be established; inspect display safety")
        }
        let observed = report
        guard observed.state == .ready else {
            throw SpaceOError.stageCreationFailed("host health refused: " + observed.reasons.joined(separator: ", ")
                + "; retain the display owner and inspect docs/DISPLAY_SAFETY.md")
        }
    }

    private func start() {
        lock.withLock {
            guard !started, current.state != .blocked else { return }
            started = true
            let timer = DispatchSource.makeTimerSource(queue: watchdog)
            timer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    /// Also driven directly by deterministic tests, without starting a timer or host sampler.
    func tick() {
        expireIfNeeded()
        let time = now()
        let shouldSample = lock.withLock { () -> Bool in
            guard current.state != .blocked, inFlightSince == nil,
                  lastAttempt.map({ time - $0 >= 5 }) ?? true else { return false }
            inFlightSince = time
            lastAttempt = time
            return true
        }
        guard shouldSample else { return }
        worker.async { [weak self] in
            guard let self else { return }
            do { self.accept(try self.sample()) }
            catch { self.fail("host_health_unknown") }
        }
    }

    func accept(_ next: DisplayHostHealthSample) {
        // Check the independent deadline even when the watchdog has not had its next tick.
        expireIfNeeded()
        var failed: String?
        lock.withLock {
            guard current.state != .blocked else { return }
            inFlightSince = nil
            // Pace from completion so a slower first sample followed by a fast one cannot
            // shrink the observation interval below the policy's minimum.
            lastAttempt = now()
            guard next.uptime.isFinite, abs(now() - next.uptime) <= 3,
                  next.diagnosticReports >= 0, [1, 2, 4].contains(next.pressure) else {
                failed = "host_health_unknown"; return
            }
            // A known incident/pressure does not need another five seconds to refuse admission.
            if next.diagnosticReports > 0 { failed = "recent_windowserver_diagnostic" }
            else if next.pressure != 1 { failed = "memory_pressure" }
            else if let previous {
                do {
                    let assessment = try DisplayHostHealthSample.assess(previous, next)
                    current = assessment
                    reportedAt = now()
                    if assessment.state == .blocked {
                        // fail() owns publishing a sticky failure and its notification.
                        current.state = .unknown
                        failed = assessment.reasons.joined(separator: ",")
                    } else { finishInitialDecision() }
                } catch { failed = "host_health_unknown" }
            }
            self.previous = next
            if failed != nil {
                current.memoryPressure = next.pressure
                current.windowServerDiagnosticReports = next.diagnosticReports
            }
        }
        if let failed { fail(failed) }
    }

    private func finishInitialDecision() {
        if waitingForInitialDecision {
            waitingForInitialDecision = false
            initialDecision.leave()
        }
    }

    private func expireIfNeeded() {
        let time = now()
        let expired = lock.withLock {
            !time.isFinite || (inFlightSince.map { time < $0 || time - $0 > 3 } ?? false)
                || (reportedAt.map { time < $0 || time - $0 > 10 } ?? false)
        }
        if expired { fail("host_health_stale_or_timed_out") }
    }

    private func fail(_ reason: String) {
        let first = lock.withLock { () -> Bool in
            guard current.state != .blocked else { return false }
            current.state = .blocked
            current.reasons = reason.split(separator: ",").map(String.init)
            timer?.cancel()
            timer = nil
            finishInitialDecision()
            return true
        }
        if first { onFailure("host health: " + reason) }
    }

    deinit { timer?.cancel() }
}
