import XCTest

final class LiveHostHealthTests: XCTestCase {
    func testOnlySuccessfulHelperExitAdmitsWork() throws {
        try LiveHostHealth.run(executable: "/usr/bin/true", arguments: [])
        XCTAssertThrowsError(try LiveHostHealth.run(executable: "/usr/bin/false", arguments: []))
        XCTAssertThrowsError(try LiveHostHealth.run(executable: "/missing-spaceo-health-helper", arguments: []))
    }

    func testMissingOrRelativeHelperIsRefused() {
        for path in [nil, "", "scripts/host-health.py", "/invalid\0path"] as [String?] {
            XCTAssertThrowsError(try LiveHostHealth.requireAdmission(scriptPath: path))
        }
    }

    func testStuckReadOnlyHelperIsBounded() {
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try LiveHostHealth.run(executable: "/bin/sleep", arguments: ["10"], timeout: 0.05)) {
            guard case LiveHostHealth.Failure.timedOut = $0 else {
                return XCTFail("expected helper deadline refusal")
            }
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
    }
}
