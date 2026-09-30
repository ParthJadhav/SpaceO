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
