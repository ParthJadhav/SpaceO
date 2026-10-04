import XCTest
@testable import SpaceOKit

final class DiagnosticCutoffTests: XCTestCase {
    func testCurrentBootReportNeverAgesOutDuringThatBoot() throws {
        let boot = 1_000_000.0
        let report = boot + 3_600
        for hours in [2.0, 14, 23, 24, 25, 48, 720] {
            let cutoff = try DisplayHostHealthSampler.diagnosticCutoff(boot: boot, now: boot + hours * 3_600)
            XCTAssertGreaterThanOrEqual(report, cutoff)
        }
    }

    func testRecentPreBootReportRemainsRelevantUntilItsFullDayExpires() throws {
        let boot = 1_000_000.0
        let report = boot - 7_200
        XCTAssertGreaterThanOrEqual(report, try DisplayHostHealthSampler.diagnosticCutoff(boot: boot, now: boot + 21 * 3_600))
        XCTAssertLessThan(report, try DisplayHostHealthSampler.diagnosticCutoff(boot: boot, now: boot + 23 * 3_600))
    }

    func testUnknownBootMetadataRefuses() {
        for (boot, now) in [(0.0, 10.0), (11, 10), (.nan, 10), (1, .infinity)] {
            XCTAssertThrowsError(try DisplayHostHealthSampler.diagnosticCutoff(boot: boot, now: now))
        }
    }
}
