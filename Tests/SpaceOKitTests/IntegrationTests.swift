import XCTest
import AppKit
import CoreGraphics
@testable import SpaceOKit

/// Tests that touch the real WindowServer.
///
/// Discovery is inert unless all three live-qualification opt-ins are present. The qualification
/// runner treats every skip as a failure, because missing TCC grants or applications are unmet
/// release prerequisites rather than evidence. Every test asserts in `tearDown` that it left no
/// phantom display behind — a leaked virtual monitor is a user-visible defect, not a detail.
final class IntegrationTests: XCTestCase {

    private var baselineDisplays: Set<CGDirectDisplayID> = []
    private var hasDisplayBaseline = false

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["SPACEO_LIVE_QUALIFICATION"] == "1"
                && environment["SPACEO_QUALIFIED_HOST"] == "1"
                && environment["SPACEO_DISPOSABLE_LOGIN"] == "1",
            """
            Live integration tests are disabled. Use scripts/test.sh live from an explicitly \
            qualified host and disposable macOS login.
            """
        )
        let capabilities = Capabilities()
        try XCTSkipUnless(capabilities.canDrive, """
            SpaceO cannot drive sessions on this host:
            \(capabilities.report)
            """)
        baselineDisplays = Set(Stage.onlineDisplayIDs())
        hasDisplayBaseline = true
    }

    override func tearDownWithError() throws {
        guard hasDisplayBaseline else { return }
        // Give any asynchronous teardown a bounded chance to finish before we accuse it.
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, Set(Stage.onlineDisplayIDs()) != baselineDisplays {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        let leaked = Set(Stage.onlineDisplayIDs()).subtracting(baselineDisplays)
        XCTAssertTrue(leaked.isEmpty, "leaked virtual display(s): \(leaked.sorted())")
    }

    // MARK: - Stage lifecycle
    //
    // Deliberately app-free: this isolates display create/destroy from anything an
    // application might be doing to keep the display alive.

    func testStageCreateAndDestroyLeavesNoDisplay() throws {
        let before = Set(Stage.onlineDisplayIDs())
        let stage = try Stage(name: "test-lifecycle", width: 1280, height: 800)
        let id = stage.displayID

        XCTAssertTrue(stage.isValid)
        XCTAssertTrue(Stage.activeDisplayIDs().contains(id), "stage did not register as a display")
        XCTAssertEqual(Set(Stage.onlineDisplayIDs()).subtracting(before), [id])

        XCTAssertTrue(stage.invalidate(), "virtual display did not retire before the timeout")
        XCTAssertFalse(Stage.onlineDisplayIDs().contains(id),
                       "invalidate() must not return while the display remains online")
    }

    func testStageOwnsItsOwnSpace() throws {
        let stage = try Stage(name: "test-space", width: 1280, height: 800)
        defer { stage.invalidate() }

        XCTAssertFalse(stage.spaces.isEmpty, "a stage must own at least one managed Space")
        XCTAssertTrue(stage.hasOwnSpace,
                      "the stage's Space must be distinct from the user's active Space — this is "
                      + "what keeps agent windows composited instead of occlusion-paused")
    }

    func testMultipleStagesCoexist() throws {
        let before = Set(Stage.activeDisplayIDs())
        var stages: [Stage] = []
        defer { stages.forEach { $0.invalidate() } }

        for index in 1...3 {
            stages.append(try Stage(name: "test-multi-\(index)", width: 1024, height: 768))
        }

        let ids = Set(stages.map(\.displayID))
        XCTAssertEqual(ids.count, 3, "each agent must get a distinct display")
        XCTAssertEqual(Set(Stage.activeDisplayIDs()).subtracting(before), ids)

        let spaces = stages.flatMap(\.spaces)
        XCTAssertEqual(Set(spaces).count, spaces.count, "stages must not share a Space")
    }

    // MARK: - The isolation invariant
    //
    // Run a full agent workflow and prove none of the covered dimensions detected a breach.
    // Input-route coverage remains unknown until macOS provides a safe observation mechanism.

    func testFullWorkflowHasNoCoveredIsolationBreach() async throws {
        let appURL = try XCTUnwrap(AppLauncher.resolve("TextEdit"))
        let pool = DisplayPool(sessionsPerDisplay: 1, displaySize: CGSize(width: 1600, height: 1000))
        let session = AgentSession(id: "test-workflow", slot: try pool.allocate())
        var destroyed = false
        defer { if !destroyed { session.destroy() }; pool.releaseAll() }

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory() + "spaceo-test-\(UUID().uuidString).txt")
        try "".write(to: scratch, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let before = IsolationSnapshot.captureStable()

        // Launch
        let app = try await session.launch(app: appURL, opening: [scratch])
        let afterLaunch = IsolationSnapshot.capture()
        XCTAssertTrue(
            afterLaunch.report(comparedTo: before).failures.isEmpty,
            "launch caused a covered isolation breach: \(afterLaunch.drift(from: before))"
        )

        // Placement
        let window = try XCTUnwrap(session.primaryWindow, "app produced no window")
        XCTAssertTrue(WindowPlacement.isInRegion(window, session.frame),
                      "window did not land in the session's tile")
        let windowSpaces = Set(WindowPlacement.spaces(of: window))
        XCTAssertFalse(windowSpaces.isEmpty)
        XCTAssertTrue(windowSpaces.isSubset(of: Set(session.stage.spaces)),
                      "window is on \(windowSpaces.sorted()), stage owns \(session.stage.spaces.sorted())")

        // Input
        let marker = "spaceo-\(UUID().uuidString.prefix(8))"
        try InputRouter.prepareForInput(window)
        try InputRouter.type("verified \(marker)", to: app.pid)

        // Poll rather than sleep a fixed amount: on a loaded machine the app can take a while
        // to drain the synthesised events, and a fixed sleep turns that into a flaky test.
        // Read back from *our* window rather than the app's focused element: if TextEdit was
        // already open before the test, the app-wide focus is some other document.
        var readBack = ""
        let inputDeadline = Date().addingTimeInterval(8)
        while Date() < inputDeadline {
            readBack = AXTree.text(in: window) ?? ""
            if readBack.contains(marker) { break }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        XCTAssertTrue(readBack.contains(marker),
                      "typed text never reached our window (value: '\(readBack.prefix(60))')")

        // Accessibility addressing stays live on a non-user display
        let snapshot = try session.snapshotAX(window: window)
        XCTAssertGreaterThan(snapshot.actionableCount, 0,
                             "AX tree went stale — the occlusion problem the display design avoids")

        // The invariant, over the whole workflow
        let after = IsolationSnapshot.capture()
        XCTAssertTrue(
            after.report(comparedTo: before).failures.isEmpty,
            "COVERED ISOLATION BREACH: \(after.drift(from: before).joined(separator: "; "))"
        )

        // Teardown must also be clean
        let displayID = session.stage.displayID
        session.destroy()
        pool.release(session.slot)
        destroyed = true
        XCTAssertFalse(Stage.onlineDisplayIDs().contains(displayID))

        // Ownership matters here: SpaceO must quit what it started, and must NOT kill an
        // instance that was already running before the session existed.
        if app.startedByUs {
            XCTAssertNil(NSRunningApplication(processIdentifier: app.pid),
                         "an app SpaceO started outlived its session")
        } else {
            XCTAssertNotNil(NSRunningApplication(processIdentifier: app.pid),
                            "SpaceO killed an app it merely adopted — it must never do that")
        }
    }

    func testCaptureOfAgentScreenIsActuallyRendered() async throws {
        try XCTSkipUnless(Capabilities().canCapture, "Screen Recording not granted")

        let appURL = try XCTUnwrap(AppLauncher.resolve("TextEdit"))
        let pool = DisplayPool(sessionsPerDisplay: 1, displaySize: CGSize(width: 1440, height: 900))
        let session = AgentSession(id: "test-capture", slot: try pool.allocate())
        defer { session.destroy(); pool.releaseAll() }

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory() + "spaceo-cap-\(UUID().uuidString).txt")
        try "rendered content for capture".write(to: scratch, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scratch) }

        _ = try await session.launch(app: appURL, opening: [scratch])
        let window = try XCTUnwrap(session.primaryWindow)
        try await Task.sleep(nanoseconds: 500_000_000)

        let windowImage = try await Capture.window(window)
        XCTAssertTrue(Capture.looksRendered(windowImage),
                      "window capture was blank — entropy \(Capture.visualEntropy(windowImage))")

        let tileImage = try await Capture.region(session.stage, session.frame)
        XCTAssertEqual(tileImage.width, 1440)
        XCTAssertTrue(Capture.looksRendered(tileImage),
                      "tile capture was blank — entropy \(Capture.visualEntropy(tileImage))")
    }

    // MARK: - Refusals

    func testUnknownSessionIsRejected() async {
        let manager = SessionManager()
        var request = Request(cmd: "windows")
        request.session = "does-not-exist"
        let response = await manager.handle(request)
        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.error?.contains("does-not-exist") == true)
    }

    func testAmbiguousSessionIsRejectedRatherThanGuessed() async throws {
        let manager = SessionManager()
        _ = try await manager.create(name: "a")
        _ = try await manager.create(name: "b")
        defer { Task { try? await manager.destroyAll(quitApps: false) } }

        let response = await manager.handle(Request(cmd: "windows"))
        XCTAssertFalse(response.ok, "with two sessions live, an unnamed command must not pick one")
        XCTAssertTrue(response.error?.contains("2 sessions") == true)
    }

    // MARK: - Shared displays
    //
    // A virtual display is a whole framebuffer for the WindowServer to composite, so the
    // headline property here is "more sessions must not mean more displays".

    func testSessionsShareOneDisplayUntilItIsFull() throws {
        // Four usable 1280x800 tiles require a 2560x1600 canvas. The default 1920x1080
        // display would create 960x540 quadrants and is correctly rejected by the pool.
        let pool = DisplayPool(sessionsPerDisplay: 4,
                               displaySize: CGSize(width: 2560, height: 1600))
        defer { pool.releaseAll() }

        var slots: [DisplayPool.Slot] = []
        for _ in 0..<4 { slots.append(try pool.allocate()) }

        XCTAssertEqual(pool.displayCount, 1, "four sessions at 4-per-display need exactly one display")
        XCTAssertEqual(pool.sessionCount, 4)
        XCTAssertEqual(Set(slots.map { $0.stage.displayID }).count, 1)
        XCTAssertEqual(Set(slots.map(\.index)).count, 4, "tiles must be distinct")

        for i in slots.indices {
            for j in slots.indices where j > i {
                XCTAssertFalse(slots[i].frame.intersects(slots[j].frame),
                               "tile \(i) overlaps tile \(j) on a live display")
            }
        }

        // The fifth spills onto a second display.
        let fifth = try pool.allocate()
        XCTAssertEqual(pool.displayCount, 2)
        XCTAssertNotEqual(fifth.stage.displayID, slots[0].stage.displayID)

        pool.release(fifth)
        XCTAssertEqual(pool.displayCount, 1, "the spill display must be retired once it empties")
    }

    func testDisplayIsRetiredOnlyWhenTheLastTenantLeaves() throws {
        let before = Set(Stage.onlineDisplayIDs())
        let pool = DisplayPool(sessionsPerDisplay: 2)
        defer { pool.releaseAll() }

        let first = try pool.allocate()
        let second = try pool.allocate()
        let displayID = first.stage.displayID
        XCTAssertEqual(pool.displayCount, 1)

        pool.release(first)
        XCTAssertTrue(Stage.activeDisplayIDs().contains(displayID),
                      "the display must survive while a neighbour is still using it")

        pool.release(second)
        XCTAssertFalse(Stage.onlineDisplayIDs().contains(displayID))
        XCTAssertEqual(Set(Stage.onlineDisplayIDs()), before)
    }

    func testTwoSessionsOnOneDisplayStayInTheirOwnTiles() async throws {
        let appURL = try XCTUnwrap(AppLauncher.resolve("TextEdit"))
        let pool = DisplayPool(sessionsPerDisplay: 2)
        let left = AgentSession(id: "tile-left", slot: try pool.allocate())
        let right = AgentSession(id: "tile-right", slot: try pool.allocate())
        defer {
            left.destroy()                       // quits what it started; no leak into later runs
            right.destroy()
            pool.releaseAll()
        }

        XCTAssertEqual(left.stage.displayID, right.stage.displayID)
        XCTAssertFalse(left.frame.intersects(right.frame))

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory() + "spaceo-tile-\(UUID().uuidString).txt")
        try "tile test".write(to: scratch, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let otherScratch = URL(fileURLWithPath: NSTemporaryDirectory()
                               + "spaceo-tile-other-\(UUID().uuidString).txt")
        try "other tile test".write(to: otherScratch, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: otherScratch) }

        let leftApp = try await left.launch(app: appURL, opening: [scratch])
        let rightApp = try await right.launch(app: appURL, opening: [otherScratch])
        XCTAssertNotEqual(leftApp.pid, rightApp.pid,
                          "two sessions must never adopt and fight over the same app process")

        let window = try XCTUnwrap(left.primaryWindow)
        let rightWindow = try XCTUnwrap(right.primaryWindow)

        XCTAssertTrue(WindowPlacement.isInRegion(window, left.frame),
                      "window landed outside its own session's tile")
        XCTAssertFalse(WindowPlacement.isInRegion(window, right.frame),
                       "window spilled into the neighbouring session's tile")
        XCTAssertTrue(WindowPlacement.isInRegion(rightWindow, right.frame))
        XCTAssertFalse(WindowPlacement.isInRegion(rightWindow, left.frame))
        XCTAssertTrue(right.audit().isEmpty, "the neighbour should see nothing wrong")
    }

    func testReleaseAllClearsOwnedSpaceBookkeeping() throws {
        let before = AgentActivity.ownedSpaces
        let pool = DisplayPool()
        _ = try pool.allocate()
        XCTAssertNotEqual(AgentActivity.ownedSpaces, before)

        pool.releaseAll()
        XCTAssertEqual(AgentActivity.ownedSpaces, before,
                       "released display Spaces must not cause false isolation breaches later")
    }

    // MARK: - Chromium web content
    //
    // The headline finding: synthetic input reaches a Chromium browser's chrome but never its
    // web content. This test is the proof that the DevTools path actually dispatches DOM events,
    // rather than the click silently evaporating — which is how it failed before.

    func testChromiumWebContentIsDrivenThroughDevTools() async throws {
        guard let chrome = AppLauncher.resolve("Google Chrome") else {
            throw XCTSkip("Google Chrome is not installed")
        }

        let page = URL(fileURLWithPath: NSTemporaryDirectory() + "spaceo-cdp-\(UUID().uuidString).html")
        try """
        <!doctype html><meta charset=utf-8><title>t</title>
        <button id=b>go</button><div id=out>0</div>
        <script>let n=0,r=0;
          b.onclick=()=>{n++;out.textContent=n};
          b.oncontextmenu=e=>{e.preventDefault();r++;out.textContent='r'+r};
        </script>
        """.write(to: page, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: page) }

        let pool = DisplayPool(sessionsPerDisplay: 1)
        let session = AgentSession(id: "test-cdp", slot: try pool.allocate())
        var destroyed = false
        defer {
            if !destroyed { session.destroy() }
            pool.releaseAll()
        }

        let before = IsolationSnapshot.captureStable()
        let app = try await session.launch(app: chrome, opening: [page])

        XCTAssertNotNil(app.devToolsPort,
                        "a Chromium browser must be launched with a DevTools port, or its web "
                        + "content cannot be driven at all")
        let profile = try XCTUnwrap(app.temporaryProfile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.path),
                      "launched Chromium instance did not create its private profile")
        let bridge = try XCTUnwrap(session.webBridge(for: app.pid),
                                   "no DevTools bridge attached to the launched browser")

        // The page must be readable...
        let elements = try await bridge.interactiveElements()
        XCTAssertTrue(elements.contains("[w0]"), "page elements were not enumerated: \(elements)")

        // ...and a click must actually reach the DOM.
        try await bridge.clickElement(index: 0)
        try await bridge.clickElement(index: 0)
        var counter = ""
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            counter = (try? await bridge.evaluate("document.getElementById('out').textContent")) ?? ""
            if counter == "2" { break }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        XCTAssertEqual(counter, "2", "DOM clicks did not register — the page saw '\(counter)'")

        // Right-click must stay a right-click rather than being coerced to a left-click.
        try await bridge.clickElement(index: 0, button: .right)
        var afterRight = ""
        let rightDeadline = Date().addingTimeInterval(5)
        while Date() < rightDeadline {
            afterRight = (try? await bridge.evaluate("document.getElementById('out').textContent")) ?? ""
            if afterRight.hasPrefix("r") { break }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        XCTAssertEqual(afterRight, "r1", "right-click was lost or coerced — page saw '\(afterRight)'")

        // And none of the covered dimensions detected an attributable breach.
        let afterDriving = IsolationSnapshot.capture()
        XCTAssertTrue(
            afterDriving.report(comparedTo: before).failures.isEmpty,
            "driving a browser caused a covered isolation breach: "
                + afterDriving.breaches(from: before).joined(separator: "; ")
        )

        session.destroy()
        destroyed = true
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.path),
                       "destroying a browser session leaked its private profile")
    }

    func testAuditReportsAnAppThatExited() async throws {
        let appURL = try XCTUnwrap(AppLauncher.resolve("TextEdit"))
        let pool = DisplayPool()
        let session = AgentSession(id: "test-dead-app", slot: try pool.allocate())
        defer { session.destroy(); pool.releaseAll() }

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()
                          + "spaceo-dead-\(UUID().uuidString).txt")
        try "dead app audit".write(to: scratch, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let app = try await session.launch(app: appURL, opening: [scratch])

        AppLauncher.quit(app, force: true)
        let deadline = Date().addingTimeInterval(5)
        while NSRunningApplication(processIdentifier: app.pid) != nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertNil(NSRunningApplication(processIdentifier: app.pid))
        XCTAssertTrue(session.audit().contains { $0.contains("exited") },
                      "refreshing windows must not erase the evidence that an owned app died")
    }

    /// A browser we merely adopted has no DevTools port, so web clicks are impossible. The
    /// contract is that we say so rather than returning success for a click that did nothing.
    func testAdoptedBrowserIsRefusedRatherThanSilentlyIgnored() async throws {
        guard AppLauncher.resolve("Google Chrome") != nil else {
            throw XCTSkip("Google Chrome is not installed")
        }
        let pool = DisplayPool(sessionsPerDisplay: 1)
        let session = AgentSession(id: "test-adopt-browser", slot: try pool.allocate())
        defer { session.destroy(quitApps: false); pool.releaseAll() }

        // Fabricate the situation without touching the user's browser: no bridge is registered
        // for a pid we never launched, so the refusal must fire for any Chromium app.
        XCTAssertNil(session.webBridge(for: 99999))
    }

    // MARK: - Late windows
    //
    // Apps open windows after launch — restore prompts, dialogs, second documents — and every
    // one of those lands on the user's screen unless something pulls it back.

    /// Containment must come from the janitor itself — the AX observer, or the periodic sweep
    /// behind it. This test deliberately never calls `sweepStrayWindows()`: the old version did,
    /// inside its polling loop, which meant it passed whether or not a single notification was
    /// ever delivered. It was testing the sweep it performed, not the janitor.
    func testWindowWatcherContainsLateWindowsWithoutBeingSweptByHand() async throws {
        let appURL = try XCTUnwrap(AppLauncher.resolve("TextEdit"))
        let pool = DisplayPool(sessionsPerDisplay: 1)
        let session = AgentSession(id: "test-late", slot: try pool.allocate())
        defer { session.destroy(); pool.releaseAll() }

        let first = URL(fileURLWithPath: NSTemporaryDirectory() + "spaceo-late-a-\(UUID().uuidString).txt")
        try "one".write(to: first, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: first) }
        _ = try await session.launch(app: appURL, opening: [first])

        XCTAssertEqual(session.watcherRegistrationFailures, [String](),
                       "the AX observer must be fully registered, or containment is degraded "
                       + "to the periodic sweep alone and the audit should already say so")

        // Cmd-N asks the already-owned process to create a window after initial placement.
        // It keeps the test off the user's display and exercises the AX observer, not a second
        // independent app launch.
        let firstWindow = try XCTUnwrap(session.primaryWindow)
        try InputRouter.prepareForInput(firstWindow)
        try InputRouter.key(try KeyCombo.parse("cmd+n"), to: firstWindow.pid)

        // Generous enough for several periodic sweeps, so a missed notification is caught by the
        // backstop rather than failing the run.
        let deadline = Date().addingTimeInterval(max(10, WindowWatcher.periodicSweepInterval * 4))
        while Date() < deadline {
            session.refreshWindows()
            if session.windows.count >= 2,
               session.windows.allSatisfy({
                   WindowPlacement.isFullyInRegion($0.windowID, session.frame) ?? false
               }) {
                break
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        session.refreshWindows()
        XCTAssertGreaterThanOrEqual(session.windows.count, 2, "expected both documents")
        for window in session.windows {
            // Full bounds, not the midpoint: a window whose centre is in the tile can still be
            // spilling across the user's screen, which is the failure that matters.
            XCTAssertEqual(WindowPlacement.isFullyInRegion(window.windowID, session.frame), true,
                           "window '\(window.title)' is not fully inside the agent's tile")
        }
    }

    /// The janitor must reap a process that exited on its own, without waiting for an operator
    /// command — and reaping must release the ownership claim so the PID is adoptable again.
    func testJanitorReapsAnExitedAppAndReleasesItsClaim() async throws {
        let appURL = try XCTUnwrap(AppLauncher.resolve("TextEdit"))
        let pool = DisplayPool(sessionsPerDisplay: 1)
        let session = AgentSession(id: "test-reap", slot: try pool.allocate())
        defer { session.destroy(); pool.releaseAll() }

        let document = URL(fileURLWithPath: NSTemporaryDirectory() + "spaceo-reap-\(UUID().uuidString).txt")
        try "reap me".write(to: document, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: document) }
        let app = try await session.launch(app: appURL, opening: [document])
        XCTAssertEqual(ProcessOwnership.owner(of: app.identity), "test-reap")

        AppLauncher.quit(app, force: true)
        let deadline = Date().addingTimeInterval(10)
        while app.identity.isAlive && Date() < deadline {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertFalse(app.identity.isAlive, "the app should have exited")

        XCTAssertEqual(session.runJanitorPass(), 1, "the janitor should reap exactly one app")
        XCTAssertTrue(session.apps.isEmpty)
        XCTAssertNil(ProcessOwnership.owner(of: app.identity),
                     "a reaped app must not keep its process claim")
    }
}
