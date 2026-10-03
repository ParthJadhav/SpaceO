import Foundation

/// Content-free observations. A ready sample is admission evidence, not an OS safety guarantee.
public struct DisplayHostHealthReport: Codable, Sendable, Equatable {
    public var state: DisplaySafetyStatus.State
    public var reasons: [String]
    public var colorsyncCPUPercent: Double?
    public var memoryPressure: UInt32?
    public var swapinsDelta: UInt64?
    public var swapoutsDelta: UInt64?
    public var windowServerDiagnosticReports: Int?
    public var unavailableInput: String?
}

struct DisplayHostHealthSample: Sendable {
    /// Launch counts come from launchd for both states, so a launch between samples is visible
    /// even when no process row exists at either sample.
    enum Service: Sendable, Equatable {
        case running(pid: Int32, start: String, cpuSeconds: Double, launches: UInt64)
        case idle(launches: UInt64)

        var isValid: Bool {
            guard case let .running(pid, start, cpuSeconds, launches) = self else { return true }
            return pid > 0 && !start.isEmpty && cpuSeconds.isFinite && cpuSeconds >= 0 && launches >= 1
        }
    }
    /// Monotonic timestamp paired with the final process CPU observation.
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
              Set(after.services.keys) == Set(DisplayHostHealthSampler.services) else { throw Unknown("sampling_interval_or_counters") }
        var cpu = 0.0
        for name in DisplayHostHealthSampler.services {
            let old = before.services[name]!, new = after.services[name]!
            guard old.isValid, new.isValid else { throw Unknown("colorsync_service_counter") }
            switch (old, new) {
            case let (.running(oldPID, oldStart, oldCPU, oldLaunches), .running(pid, start, newCPU, launches)):
                guard oldPID == pid, oldStart == start, newCPU >= oldCPU else { throw Unknown("colorsync_service_changed") }
                guard oldLaunches == launches else { throw Unknown("colorsync_launch_count_changed") }
                cpu += (newCPU - oldCPU) / elapsed * 100
            case let (.idle(oldLaunches), .idle(launches)):
                // No launch between the two launchd reads, so no service CPU in the interval.
                guard oldLaunches == launches else { throw Unknown("colorsync_launch_count_changed") }
            case let (.idle(oldLaunches), .running(_, _, newCPU, launches)):
                // Exactly one launch: its whole lifetime CPU bounds all service work since the
                // idle read. Any further launch could hide an exited instance's CPU.
                guard oldLaunches < UInt64.max, launches == oldLaunches + 1 else {
                    throw Unknown("colorsync_launch_count_changed")
                }
                cpu += newCPU / elapsed * 100
            case (.running, .idle):
                throw Unknown("colorsync_service_transition")
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
                     colorsyncCPUPercent: cpu, memoryPressure: after.pressure,
                     swapinsDelta: swapins, swapoutsDelta: swapouts,
                     windowServerDiagnosticReports: reports)
    }

    struct Unknown: Error {
        let reason: String
        init(_ reason: String = "host_health_unknown") { self.reason = reason }
    }
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
        guard initialDecision.wait(timeout: .now() + 15) == .success else {
            fail("host_health_timeout")
            throw SpaceOError.stageCreationFailed("host health could not be established; inspect display safety")
        }
        let observed = report
        guard observed.state == .ready else {
            throw SpaceOError.stageCreationFailed("host health refused: " + observed.reasons.joined(separator: ", ")
                + (observed.unavailableInput.map { " (unavailable input: \($0))" } ?? "")
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
            catch let error as DisplayHostHealthSample.Unknown { self.fail("host_health_unknown", unavailableInput: error.reason) }
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
            guard next.uptime.isFinite, abs(now() - next.uptime) <= 3,
                  next.diagnosticReports >= 0, [1, 2, 4].contains(next.pressure) else {
                failed = "host_health_unknown"; return
            }
            // Pace from the CPU observation, rather than trailing validation completion.
            // Each next observation is at least five seconds later without adding both
            // captures' helper budgets to the policy's maximum sampling interval.
            lastAttempt = next.uptime
            // A known incident/pressure does not need another five seconds to refuse admission.
            if next.diagnosticReports > 0 { failed = "recent_windowserver_diagnostic" }
            else if next.pressure != 1 { failed = "memory_pressure" }
            else if let previous {
                do {
                    let assessment = try DisplayHostHealthSample.assess(previous, next)
                    current = assessment
                    reportedAt = next.uptime
                    if assessment.state == .blocked {
                        // fail() owns publishing a sticky failure and its notification.
                        current.state = .unknown
                        failed = assessment.reasons.joined(separator: ",")
                    } else { finishInitialDecision() }
                } catch let error as DisplayHostHealthSample.Unknown {
                    current.unavailableInput = error.reason
                    failed = "host_health_unknown"
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

    private func fail(_ reason: String, unavailableInput: String? = nil) {
        let first = lock.withLock { () -> Bool in
            guard current.state != .blocked else { return false }
            current.state = .blocked
            if let unavailableInput { current.unavailableInput = unavailableInput }
            current.reasons = reason.split(separator: ",").map(String.init)
            timer?.cancel()
            timer = nil
            finishInitialDecision()
            return true
        }
        if first {
            let input = lock.withLock { current.unavailableInput }
            onFailure("host health: " + reason + (input.map { " (\($0))" } ?? ""))
        }
    }

    deinit { timer?.cancel() }
}
