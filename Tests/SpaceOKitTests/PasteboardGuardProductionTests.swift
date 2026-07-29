import XCTest
import AppKit
@testable import SpaceOKit

/// Production-path regressions for SPAO-133's fail-closed shared-pasteboard policy.
final class PasteboardGuardProductionTests: XCTestCase {

    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: .init("spaceo.pasteboard-production.\(UUID().uuidString)"))
    }

    private func setString(_ value: String, on pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(value, forType: .string))
    }

    private func assertClipboardRefusal(
        _ error: Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .unsupportedTarget(let message) = error as? SpaceOError else {
            XCTFail("expected clipboard-safe route refusal, got \(error)", file: file, line: line)
            return
        }
        XCTAssertTrue(message.contains("no atomic way"), file: file, line: line)
        XCTAssertTrue(message.contains("isolated clipboard broker"), file: file, line: line)
    }

    private func assertClipboardRefusal(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> Void
    ) {
        do {
            try operation()
            XCTFail("expected clipboard-safe route refusal", file: file, line: line)
        } catch {
            assertClipboardRefusal(error, file: file, line: line)
        }
    }

    // MARK: - Production routes fail before dispatch

    func testNativeCopyAndCutFailClosedBeforePosting() throws {
        for shortcut in ["cmd+c", "cmd+x", "cmd+shift+c", "cmd+option+x"] {
            let pasteboard = makePasteboard()
            defer { pasteboard.releaseGlobally() }
            setString("user-\(shortcut)", on: pasteboard)
            var dispatched = false

            assertClipboardRefusal {
                try InputRouter.deliverKey(
                    KeyCombo.parse(shortcut),
                    pasteboard: pasteboard
                ) {
                    dispatched = true
                    self.setString("agent", on: pasteboard)
                }
            }

            XCTAssertFalse(dispatched)
            XCTAssertEqual(pasteboard.string(forType: .string), "user-\(shortcut)")
        }
    }

    func testDevToolsCopyAndCutFailClosedBeforeAnyCDPDispatch() async throws {
        for shortcut in ["cmd+c", "cmd+x", "cmd+shift+c", "cmd+control+x"] {
            let pasteboard = makePasteboard()
            defer { pasteboard.releaseGlobally() }
            setString("user-\(shortcut)", on: pasteboard)
            var dispatchCount = 0

            do {
                try await ChromiumBridge.deliverKey(
                    KeyCombo.parse(shortcut),
                    pasteboard: pasteboard
                ) { _ in
                    dispatchCount += 1
                    self.setString("agent", on: pasteboard)
                }
                XCTFail("expected \(shortcut) to fail closed")
            } catch {
                assertClipboardRefusal(error)
            }

            XCTAssertEqual(dispatchCount, 0)
            XCTAssertEqual(pasteboard.string(forType: .string), "user-\(shortcut)")
        }
    }

    func testEmptyAndMultiItemClipboardsAreUntouchedByRefusedCommands() async throws {
        do {
            let pasteboard = makePasteboard()
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents()
            let before = PasteboardGuard.snapshot(from: pasteboard)

            assertClipboardRefusal {
                try InputRouter.deliverKey(
                    KeyCombo.parse("cmd+c"), pasteboard: pasteboard
                ) {
                    XCTFail("native event must not be posted")
                }
            }

            let after = PasteboardGuard.snapshot(from: pasteboard)
            XCTAssertEqual(after.items, before.items)
            XCTAssertEqual(after.changeCount, before.changeCount)
        }

        do {
            let pasteboard = makePasteboard()
            defer { pasteboard.releaseGlobally() }
            let first = NSPasteboardItem()
            first.setString("first", forType: .string)
            let customType = NSPasteboard.PasteboardType("dev.spaceo.test-data")
            let second = NSPasteboardItem()
            second.setData(Data([1, 2, 3, 4]), forType: customType)
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.writeObjects([first, second]))
            let before = PasteboardGuard.snapshot(from: pasteboard)

            do {
                try await ChromiumBridge.deliverKey(
                    KeyCombo.parse("cmd+x"), pasteboard: pasteboard
                ) { _ in
                    XCTFail("CDP event must not be dispatched")
                }
                XCTFail("expected clipboard route refusal")
            } catch {
                assertClipboardRefusal(error)
            }

            let after = PasteboardGuard.snapshot(from: pasteboard)
            XCTAssertEqual(after.items, before.items)
            XCTAssertEqual(after.changeCount, before.changeCount)
        }
    }

    func testOrdinaryAndShiftedWebKeysStillDispatchWithCorrectDOMKey() async throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        setString("user", on: pasteboard)
        var shiftedDown: [String: Any]?

        try await ChromiumBridge.deliverKey(
            KeyCombo.parse("shift+c"), pasteboard: pasteboard
        ) { parameters in
            if parameters["type"] as? String == "rawKeyDown" {
                shiftedDown = parameters
            }
        }

        XCTAssertEqual(shiftedDown?["key"] as? String, "C")
        XCTAssertEqual(shiftedDown?["code"] as? String, "KeyC")
        XCTAssertEqual(shiftedDown?["modifiers"] as? Int, 8)
        XCTAssertNil(shiftedDown?["commands"])
        XCTAssertEqual(pasteboard.string(forType: .string), "user")
    }

    func testConcurrentUserCopyCannotBeOverwrittenAfterRefusal() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        setString("older-user-value", on: pasteboard)
        let userCopyFinished = DispatchSemaphore(value: 0)

        assertClipboardRefusal {
            try InputRouter.deliverKey(
                KeyCombo.parse("cmd+c"), pasteboard: pasteboard
            ) {
                XCTFail("native event must not be posted")
            }
        }

        DispatchQueue.global().async {
            pasteboard.clearContents()
            pasteboard.setString("newer-user-value", forType: .string)
            userCopyFinished.signal()
        }
        XCTAssertEqual(userCopyFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(pasteboard.string(forType: .string), "newer-user-value")
    }

    // MARK: - Bounded diagnostic snapshot support

    private final class LazyProvider: NSObject, NSPasteboardItemDataProvider {
        let delay: TimeInterval
        let data: Data
        let finished = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var calls = 0

        var callCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }

        init(delay: TimeInterval, data: Data) {
            self.delay = delay
            self.data = data
        }

        func pasteboard(
            _ pasteboard: NSPasteboard?,
            item: NSPasteboardItem,
            provideDataForType type: NSPasteboard.PasteboardType
        ) {
            lock.lock()
            calls += 1
            lock.unlock()
            Thread.sleep(forTimeInterval: delay)
            item.setData(data, forType: type)
            finished.signal()
        }
    }

    func testProductionRefusalDoesNotMaterializeLazyOrOversizedClipboardValues() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let provider = LazyProvider(
            delay: 0.2, data: Data(repeating: 7, count: 33 * 1_048_576))
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.init("dev.spaceo.lazy-large")])
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))

        assertClipboardRefusal {
            try InputRouter.deliverKey(
                KeyCombo.parse("cmd+x"), pasteboard: pasteboard
            ) {
                XCTFail("native event must not be posted")
            }
        }

        XCTAssertEqual(provider.callCount, 0)
        XCTAssertEqual(pasteboard.changeCount, 1)
    }

    func testDiagnosticSnapshotsBoundCountsAndBytes() {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let first = NSPasteboardItem()
        first.setData(Data(repeating: 1, count: 6), forType: .init("test.first"))
        let second = NSPasteboardItem()
        second.setData(Data(repeating: 2, count: 6), forType: .init("test.second"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([first, second]))

        XCTAssertEqual(
            PasteboardGuard.snapshot(
                from: pasteboard, limits: .init(maximumItems: 1)
            ).failure,
            .tooManyItems(limit: 1))
        XCTAssertEqual(
            PasteboardGuard.snapshot(
                from: pasteboard, limits: .init(maximumTypes: 1)
            ).failure,
            .tooManyTypes(limit: 1))
        XCTAssertEqual(
            PasteboardGuard.snapshot(
                from: pasteboard, limits: .init(maximumBytesPerValue: 5)
            ).failure,
            .valueTooLarge(limit: 5))
        XCTAssertEqual(
            PasteboardGuard.snapshot(
                from: pasteboard,
                limits: .init(maximumBytesPerValue: 10, maximumTotalBytes: 10)
            ).failure,
            .aggregateTooLarge(limit: 10))
    }

    func testDiagnosticLazyReadTimeoutHasOneWorkerMaximum() {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let provider = LazyProvider(delay: 0.2, data: Data("eventual".utf8))
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.init("dev.spaceo.stuck-provider")])
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let limits = PasteboardGuard.Limits(snapshotTimeout: 0.01)

        for _ in 0..<8 {
            XCTAssertEqual(
                PasteboardGuard.snapshot(from: pasteboard, limits: limits).failure,
                .timedOut)
        }

        XCTAssertEqual(provider.callCount, 1)
        _ = provider.finished.wait(timeout: .now() + 1)
    }
}
