import XCTest
@testable import SpaceOKit

final class DisplayHostHealthTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var time = 100.0
        var value: Double {
            get { lock.withLock { time } }
            set { lock.withLock { time = newValue } }
        }
    }

    private func sample(_ time: Double = 100, cpu: Double = 10, pressure: UInt32 = 1,
                        swap: UInt64 = 50, reports: Int = 0, pid: Int32 = 1,
                        start: String = "start") -> DisplayHostHealthSample {
        .init(uptime: time, pressure: pressure, swapins: swap, swapouts: 100,
              services: Dictionary(uniqueKeysWithValues: DisplayHostHealthSampler.services.enumerated().map {
                  ($0.element, .init(pid: pid + Int32($0.offset), start: start, cpuSeconds: cpu))
              }), diagnosticReports: reports)
    }

    func testPolicyRejectsPressureSwapBusyColorSyncAndIncidentReports() throws {
        XCTAssertEqual(try DisplayHostHealthSample.assess(sample(), sample(105)).state, .ready)
        for (after, reason) in [(sample(105, cpu: 11.25), "colorsync_busy"),
                                (sample(105, pressure: 2), "memory_pressure"),
                                (sample(105, swap: 51), "swap_activity"),
                                (sample(105, reports: 1), "recent_windowserver_diagnostic")] {
            let report = try DisplayHostHealthSample.assess(sample(), after)
            XCTAssertEqual(report.state, .blocked)
            XCTAssertTrue(report.reasons.contains(reason))
        }
    }

    func testUnknownCountersNeverBecomeHealthy() {
        for after in [sample(103), sample(111), sample(105, cpu: 9), sample(105, cpu: .nan),
                      sample(105, swap: 49), sample(105, pid: 2), sample(105, start: "restarted"),
                      sample(105, pressure: 0)] {
            XCTAssertThrowsError(try DisplayHostHealthSample.assess(sample(), after))
        }
    }

    func testCachedHealthExpiresAndLateHealthySamplesCannotResetIt() {
        let clock = Clock()
        let failed = expectation(description: "one sticky failure")
        failed.assertForOverFulfill = true
        let monitor = DisplayHostHealth(sample: { throw DisplayHostHealthSample.Unknown() },
                                       now: { clock.value }, onFailure: { _ in failed.fulfill() })
        XCTAssertEqual(monitor.report.state, .unknown)
        XCTAssertFalse(monitor.hasStarted)
        monitor.accept(sample())
        XCTAssertEqual(monitor.report.state, .unknown)
        clock.value = 105
        monitor.accept(sample(105))
        XCTAssertEqual(monitor.report.state, .ready)
        clock.value = 116
        XCTAssertEqual(monitor.report.state, .blocked)
        monitor.accept(sample(116))
        monitor.accept(sample(121))
        XCTAssertThrowsError(try monitor.requireHealthy())
        XCTAssertEqual(monitor.report.state, .blocked)
        wait(for: [failed], timeout: 1)
    }

    func testStuckSamplerHasOneWorkerAndLateResultCannotResume() {
        let clock = Clock()
        let entered = expectation(description: "sampler started once")
        entered.assertForOverFulfill = true
        let exited = expectation(description: "late sampler exited")
        let release = DispatchSemaphore(value: 0)
        let first = sample()
        let monitor = DisplayHostHealth(sample: {
            entered.fulfill()
            release.wait()
            exited.fulfill()
            return first
        }, now: { clock.value })
        monitor.tick()
        wait(for: [entered], timeout: 1)
        clock.value = 104
        monitor.tick()
        XCTAssertEqual(monitor.report.state, .blocked)
        clock.value = 120
        for _ in 0..<100 { monitor.tick() }
        release.signal()
        wait(for: [exited], timeout: 1)
        XCTAssertEqual(monitor.report.state, .blocked)
    }

    func testIncidentRefusesWithoutWaitingForSecondSample() {
        let clock = Clock()
        let monitor = DisplayHostHealth(now: { clock.value })
        monitor.accept(sample(reports: 1))
        XCTAssertEqual(monitor.report.reasons, ["recent_windowserver_diagnostic"])
        XCTAssertThrowsError(try monitor.requireHealthy())
    }

    func testSamplerDoesNotStartBeforeFiveSecondsAfterCompletion() {
        let clock = Clock()
        clock.value = 102
        let sampled = expectation(description: "no compressed three-second sample")
        sampled.isInverted = true
        let result = sample(105)
        let monitor = DisplayHostHealth(sample: { sampled.fulfill(); return result }, now: { clock.value })
        monitor.accept(sample(102))
        clock.value = 105
        monitor.tick()
        wait(for: [sampled], timeout: 0.05)
        XCTAssertEqual(monitor.report.state, .unknown)
    }

    func testProcessParserRequiresBothExactServiceIdentities() throws {
        let lines = DisplayHostHealthSampler.services.enumerated().map {
            "\($0.offset + 10) Tue Sep 29 20:00:00 2026 01:02.50 \($0.element)"
        }
        let parsed = try DisplayHostHealthSampler.parseServices(lines.joined(separator: "\n"))
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed.values.first?.cpuSeconds, 62.5)
        XCTAssertThrowsError(try DisplayHostHealthSampler.parseServices(lines[0]))
        XCTAssertThrowsError(try DisplayHostHealthSampler.parseServices((lines + [lines[0]]).joined(separator: "\n")))
        XCTAssertEqual(try DisplayHostHealthSampler.cpuSeconds("1-02:03:04.5"), 93_784.5)
        for bad in ["NaN", "00:60", "1:99:00", "-1:02", "1:inf"] {
            XCTAssertThrowsError(try DisplayHostHealthSampler.cpuSeconds(bad))
        }
    }

    private func idleRecord(_ service: String) -> String {
        """
        system/service = {
        \tprogram = \(service)
        \tstate = not running
        \tactive count = 0
        \truns = 23
        \tlast exit reason = JETSAM_REASON_MEMORY_IDLE_EXIT
        \tproperties = supports pressured exit | system service
        \tendpoints = {
        \t\tstate = active
        \t}
        }
        """
    }

    func testIdleServiceRequiresExactTopLevelMemoryIdleExitEvidence() throws {
        let service = DisplayHostHealthSampler.services[0]
        let record = idleRecord(service)
        XCTAssertEqual(try DisplayHostHealthSampler.idleService(record, service: service), .idle(launches: 23))
        for bad in [record.replacingOccurrences(of: "not running", with: "running"),
                    record.replacingOccurrences(of: "MEMORY_IDLE_EXIT", with: "MEMORY_HIGHWATER"),
                    record.replacingOccurrences(of: "active count = 0", with: "active count = 1"),
                    record.replacingOccurrences(of: "supports pressured exit", with: "unsupported"),
                    record.replacingOccurrences(of: "runs = 23", with: "runs = -1"),
                    record.replacingOccurrences(of: "\tstate = not running\n", with: ""),
                    record + "\n\tpid = 42", record + "\n\tlast terminating signal = 9",
                    record + "\n\tlast exit code = 1", record + "\n\tstate = not running",
                    idleRecord("/private/other")] {
            XCTAssertThrowsError(try DisplayHostHealthSampler.idleService(bad, service: service))
        }
    }

    private func withServices(_ time: Double, _ services: [String: DisplayHostHealthSample.Service],
                              pressure: UInt32 = 1, reports: Int = 0) -> DisplayHostHealthSample {
        .init(uptime: time, pressure: pressure, swapins: 50, swapouts: 100,
              services: services, diagnosticReports: reports)
    }

    func testStableIdleDoesNotInventCountersOrMaskBusyRunningPeer() throws {
        let names = DisplayHostHealthSampler.services
        let idle = Dictionary(uniqueKeysWithValues: names.map { ($0, DisplayHostHealthSample.Service.idle(launches: 23)) })
        let before = withServices(100, idle)
        let report = try DisplayHostHealthSample.assess(before, withServices(105, idle))
        XCTAssertEqual(report.state, .ready)
        XCTAssertEqual(report.colorsyncIdleServices, 2)
        XCTAssertEqual(report.colorsyncCPUPercent, 0)
        XCTAssertEqual(try DisplayHostHealthSample.assess(before, withServices(105, idle, pressure: 2)).state, .blocked)
        XCTAssertEqual(try DisplayHostHealthSample.assess(before, withServices(105, idle, reports: 1)).state, .blocked)
        var old = idle, new = idle
        old[names[1]] = .running(pid: 42, start: "start", cpuSeconds: 10)
        new[names[1]] = .running(pid: 42, start: "start", cpuSeconds: 12.5)
        let busy = try DisplayHostHealthSample.assess(withServices(100, old), withServices(105, new))
        XCTAssertEqual(busy.colorsyncIdleServices, 1)
        XCTAssertTrue(busy.reasons.contains("colorsync_busy"))
    }

    func testIdleTransitionsAndInterveningLaunchRemainUnknown() {
        let name = DisplayHostHealthSampler.services[0]
        let transitions: [(DisplayHostHealthSample.Service, DisplayHostHealthSample.Service)] = [(.idle(launches: 23), .idle(launches: 24)),
                           (.idle(launches: 23), .running(pid: 42, start: "start", cpuSeconds: 10)),
                           (.running(pid: 42, start: "start", cpuSeconds: 10), .idle(launches: 23))]
        for (old, new) in transitions {
            var before = sample().services, after = sample().services
            before[name] = old; after[name] = new
            XCTAssertThrowsError(try DisplayHostHealthSample.assess(withServices(100, before), withServices(105, after)))
        }
    }

    func testIdleSampleReconcilesLaunchdAndProcessIdentity() throws {
        let records = DisplayHostHealthSampler.services.map(idleRecord)
        func read(_ values: [String]) -> (String, [String]) throws -> String {
            var cursor = 0
            return { _, _ in
                guard cursor < values.count else { throw DisplayHostHealthSample.Unknown() }
                defer { cursor += 1 }
                return values[cursor]
            }
        }
        let idle = try DisplayHostHealthSampler.serviceSample(read: read(["", records[0], records[1], ""]))
        XCTAssertTrue(idle.values.allSatisfy { $0 == .idle(launches: 23) })
        let line = "42 Tue Sep 29 20:00:00 2026 00:01.00 " + DisplayHostHealthSampler.services[0]
        XCTAssertThrowsError(try DisplayHostHealthSampler.serviceSample(read: read(["", records[0], records[1], line])))
        XCTAssertThrowsError(try DisplayHostHealthSampler.serviceSample(read: read([line, records[1], line.replacingOccurrences(of: "42 Tue", with: "43 Tue")])))
        XCTAssertThrowsError(try DisplayHostHealthSampler.serviceSample(read: { _, _ in throw DisplayHostHealthSample.Unknown() }))
    }

    func testMetadataScanIsBoundedAndRejectsSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let report = root.appendingPathComponent("WindowServer-example.ips")
        try Data("unread report content".utf8).write(to: report)
        XCTAssertEqual(try DisplayHostHealthSampler.diagnosticReports(roots: [(root.path, true)], since: 0), 1)
        XCTAssertThrowsError(try DisplayHostHealthSampler.diagnosticReports(roots: [(root.path, true)], since: 0, maximumEntries: 0))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("WindowServer-link.ips"), withDestinationURL: report)
        XCTAssertThrowsError(try DisplayHostHealthSampler.diagnosticReports(roots: [(root.path, true)], since: 0))
    }

    func testReadOnlyHelperDeadlineAndOutputLimit() throws {
        XCTAssertEqual(try DisplayHostHealthSampler.readHelper(executable: "/usr/bin/printf", arguments: ["safe"]), "safe")
        XCTAssertThrowsError(try DisplayHostHealthSampler.readHelper(executable: "/usr/bin/printf", arguments: ["too large"], maximumBytes: 2))
        let start = ContinuousClock.now
        XCTAssertThrowsError(try DisplayHostHealthSampler.readHelper(executable: "/bin/sleep", arguments: ["3"], timeout: 0.05))
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
    }
}
