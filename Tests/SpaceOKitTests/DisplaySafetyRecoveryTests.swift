import XCTest
@testable import SpaceOKit

final class DisplaySafetyRecoveryTests: XCTestCase {
    private func fixture(_ journal: [String: Any], body: (String) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("display-safety.json")
        try JSONSerialization.data(withJSONObject: journal).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try body(file.path)
    }
    private var unknown: [String: Any] {
        ["attempts": [100.0], "dayAttempts": [50.0, 100.0], "pending": false,
         "failure": "host health: host_health_unknown"]
    }

    func testRecoveryArchivesLatchInPlaceAndPreservesCreationBudgets() throws {
        try fixture(unknown) { path in
            let inode = try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? NSNumber
            var validated = false
            let archive = try DisplayLifecycleLease.clearHostHealthLatch(path: path) { validated = true }
            XCTAssertTrue(validated)
            XCTAssertEqual(DisplayLifecycleLease.status(path: path).state, .ready)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? NSNumber, inode)
            let cleared = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
            XCTAssertNil(cleared["failure"])
            XCTAssertEqual(cleared["attempts"] as? [Double], [100])
            XCTAssertEqual(cleared["dayAttempts"] as? [Double], [50, 100])
            let archived = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: archive))) as? [String: Any])
            XCTAssertEqual(archived["failure"] as? String, "host health: host_health_unknown")
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: archive)[.posixPermissions] as? NSNumber, 0o600)
        }
    }

    func testPendingMutationLiveCaseAndOtherFailureReasonsCannotBeCleared() throws {
        for (key, value) in [("pending", true as Any), ("liveTestPending", true as Any),
                             ("failure", "host health: memory_pressure" as Any),
                             ("failure", "removal was not confirmed" as Any)] {
            var journal = unknown; journal[key] = value
            try fixture(journal) { path in
                let before = try Data(contentsOf: URL(fileURLWithPath: path))
                XCTAssertThrowsError(try DisplayLifecycleLease.clearHostHealthLatch(path: path) { XCTFail("ineligible journal must not reach host validation") })
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before)
            }
        }
    }

    func testHostRefusalAndActiveOwnerCannotClearLatch() throws {
        try fixture(unknown) { path in
            let before = try Data(contentsOf: URL(fileURLWithPath: path))
            XCTAssertThrowsError(try DisplayLifecycleLease.clearHostHealthLatch(path: path) { throw SpaceOError.badRequest("host is not recovered") })
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before)
            let owner = DisplayLifecycleLease(path: path)
            XCTAssertThrowsError(try owner.acquire()) // Acquired owner lock remains held despite the latch.
            XCTAssertThrowsError(try DisplayLifecycleLease.clearHostHealthLatch(path: path) { XCTFail("owner exclusion precedes recovery") })
            withExtendedLifetime(owner) {}
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before)
        }
    }

    func testExpiredRecoveryCannotClearAfterArchiving() throws {
        try fixture(unknown) { path in
            let before = try Data(contentsOf: URL(fileURLWithPath: path))
            var checks = 0
            XCTAssertThrowsError(try DisplayLifecycleLease.clearHostHealthLatch(path: path, checkDeadline: {
                checks += 1
                if checks == 3 { throw SpaceOError.badRequest("deadline expired") }
            }) {})
            XCTAssertEqual(checks, 3)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before)
        }
    }

    func testRecoveryRejectsNonPrivateAndMalformedJournal() throws {
        try fixture(unknown) { path in
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
            XCTAssertThrowsError(try DisplayLifecycleLease.clearHostHealthLatch(path: path) {})
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            try Data("{bad".utf8).write(to: URL(fileURLWithPath: path))
            XCTAssertThrowsError(try DisplayLifecycleLease.clearHostHealthLatch(path: path) {})
        }
    }
}
