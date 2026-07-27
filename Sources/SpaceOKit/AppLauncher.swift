import Foundation
import AppKit
import CoreGraphics

/// An application SpaceO started (or adopted) on behalf of an agent.
public struct LaunchedApp: Sendable, Equatable {
    public let pid: pid_t
    public let bundleIdentifier: String?
    public let name: String
    public let url: URL
    /// False when SpaceO adopted an already-running app rather than starting it.
    public let startedByUs: Bool
    /// DevTools port, for Chromium browsers SpaceO launched itself. Synthetic input cannot
    /// reach Chromium web content, so this is the only way to click a page. An adopted
    /// browser has none, because the port can only be set at launch.
    public var devToolsPort: Int?
    /// Private Chromium profile created for this app. Removed after the process exits.
    public var temporaryProfile: URL?
}

/// Starts applications without activating them.
///
/// `activates = false` is what keeps the menu bar with the user. Combined with immediate
/// relocation onto the stage, the app never meaningfully appears on the user's screen.
public enum AppLauncher {

    /// Launch `appURL` (optionally opening `files`) and place all its windows in `region`.
    ///
    /// Requests a separate process, but accepts application substitution when macOS reuses one.
    public static func launch(
        appURL: URL,
        opening files: [URL] = [],
        into region: CGRect,
        timeout: TimeInterval = 15
    ) async throws -> (app: LaunchedApp, windows: [WindowRef]) {

        guard timeout.isFinite, (0.5...120).contains(timeout) else {
            throw SpaceOError.badRequest(
                "launch timeout must be a finite value from 0.5 through 120 seconds")
        }
        try WindowPlacement.validate(frame: region)
        guard appURL.path.count <= 4_096, appURL.path.utf8.count <= 16_384 else {
            throw SpaceOError.badRequest(
                "application path must be at most 4096 characters and 16384 UTF-8 bytes")
        }
        guard files.count <= 256,
              files.allSatisfy({
                  $0.path.count <= 4_096 && $0.path.utf8.count <= 16_384
              }) else {
            throw SpaceOError.badRequest(
                "launch accepts at most 256 files, each at most 4096 characters "
                + "and 16384 UTF-8 bytes")
        }
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            throw SpaceOError.launchFailed("no such application: \(appURL.path)")
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false           // the whole point
        configuration.addsToRecentItems = false
        configuration.hides = false
        configuration.promptsUserIfNeeded = false
        configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false

        // A Chromium browser needs a DevTools port to be driveable at all (synthetic input does
        // not reach its web content), and a port can only be set at launch. Giving it a private
        // profile at the same time is not incidental: it forces a genuinely separate instance
        // so we are not attaching to — or disturbing — the user's own browser and its cookies.
        var devToolsPort: Int?
        var temporaryProfile: URL?
        if isChromiumFamily(appURL) {
            let profile = FileManager.default.temporaryDirectory
                .appendingPathComponent("spaceo-browser-\(getpid())-\(UUID().uuidString)",
                                        isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: profile,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
            } catch {
                throw SpaceOError.launchFailed(
                    "could not create a private browser profile: \(error.localizedDescription)")
            }
            configuration.arguments = [
                // Port zero makes Chromium bind its own socket atomically. Reserving a "free"
                // port and closing it before launch leaves a race in which another process can
                // claim the port and impersonate the DevTools endpoint.
                "--remote-debugging-port=0",
                "--remote-debugging-address=127.0.0.1",
                "--user-data-dir=\(profile.path)",
                "--no-first-run",
                "--no-default-browser-check",
                "--disable-session-crashed-bubble",
            ]
            temporaryProfile = profile
        }

        let existing = runningInstances(of: appURL)
        let runningApp: NSRunningApplication
        do {
            if files.isEmpty {
                runningApp = try await NSWorkspace.shared.openApplication(at: appURL,
                                                                          configuration: configuration)
            } else {
                runningApp = try await NSWorkspace.shared.open(files,
                                                               withApplicationAt: appURL,
                                                               configuration: configuration)
            }
        } catch {
            removeTemporaryProfile(at: temporaryProfile)
            throw SpaceOError.launchFailed("\(appURL.lastPathComponent): \(error.localizedDescription)")
        }

        let reusedExistingProcess = existing.contains(runningApp.processIdentifier)
        if reusedExistingProcess {
            removeTemporaryProfile(at: temporaryProfile)
            temporaryProfile = nil
        }

        if let profile = temporaryProfile {
            devToolsPort = await waitForDevToolsPort(in: profile, timeout: min(timeout, 10))
        }

        let app = LaunchedApp(pid: runningApp.processIdentifier,
                              bundleIdentifier: runningApp.bundleIdentifier,
                              name: runningApp.localizedName ?? appURL.deletingPathExtension().lastPathComponent,
                              url: appURL,
                              startedByUs: !reusedExistingProcess,
                              devToolsPort: devToolsPort,
                              temporaryProfile: temporaryProfile)

        do {
            _ = try await WindowPlacement.waitForWindow(of: app.pid, timeout: timeout)
            // Settle: some apps resize themselves right after the first window appears.
            try? await Task.sleep(nanoseconds: 300_000_000)
            let placed = try WindowPlacement.placeAll(of: app.pid, into: region)
            return (app, placed)
        } catch {
            if app.startedByUs {
                // A failed launch must not leave an invisible process or profile behind.
                runningApp.terminate()
                let deadline = Date().addingTimeInterval(2)
                while runningApp.isTerminated == false && Date() < deadline {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if !runningApp.isTerminated { runningApp.forceTerminate() }
                let hardDeadline = Date().addingTimeInterval(2)
                while NSRunningApplication(processIdentifier: app.pid) != nil,
                      Date() < hardDeadline {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            cleanupTemporaryProfileEventually(for: app)
            throw error
        }
    }

    /// Adopt an already-running process into a stage without launching anything.
    public static func adopt(pid: pid_t, into region: CGRect) throws -> (app: LaunchedApp, windows: [WindowRef]) {
        guard pid > 0 else {
            throw SpaceOError.badRequest("adopt needs a positive pid")
        }
        try WindowPlacement.validate(frame: region)
        guard let running = NSRunningApplication(processIdentifier: pid) else {
            throw SpaceOError.launchFailed("no running application with pid \(pid)")
        }
        let app = LaunchedApp(pid: pid,
                              bundleIdentifier: running.bundleIdentifier,
                              name: running.localizedName ?? "pid \(pid)",
                              url: running.bundleURL ?? URL(fileURLWithPath: "/"),
                              startedByUs: false,
                              devToolsPort: nil,
                              temporaryProfile: nil)
        let placed = try WindowPlacement.placeAll(of: pid, into: region)
        return (app, placed)
    }

    /// Ask an app to quit politely. Never force-kills apps we did not start.
    public static func quit(_ app: LaunchedApp, force: Bool = false) {
        guard let running = NSRunningApplication(processIdentifier: app.pid) else { return }
        if force && app.startedByUs {
            running.forceTerminate()
        } else {
            running.terminate()
        }
    }

    /// Remove the private browser profile after its process is gone.
    ///
    /// The parent and prefix checks are deliberate: cleanup must never turn an unexpected path
    /// into a recursive delete outside SpaceO's own temporary directory.
    @discardableResult
    public static func cleanupTemporaryProfile(for app: LaunchedApp) -> Bool {
        guard NSRunningApplication(processIdentifier: app.pid) == nil else { return false }
        return removeTemporaryProfile(at: app.temporaryProfile)
    }

    /// A force-termination request is asynchronous. Retain cleanup responsibility briefly
    /// instead of either deleting a live browser's profile or forgetting the directory forever.
    public static func cleanupTemporaryProfileEventually(for app: LaunchedApp) {
        guard !cleanupTemporaryProfile(for: app),
              let profile = app.temporaryProfile else { return }
        scheduleTemporaryProfileCleanup(pid: app.pid, profile: profile)
    }

    private static func scheduleTemporaryProfileCleanup(pid: pid_t, profile: URL) {
        Task.detached(priority: .utility) {
            for _ in 0..<300 {
                guard NSRunningApplication(processIdentifier: pid) != nil else {
                    _ = removeTemporaryProfile(at: profile)
                    return
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    @discardableResult
    private static func removeTemporaryProfile(at candidate: URL?) -> Bool {
        guard let candidate else { return true }
        let profile = candidate.standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL
        guard profile.deletingLastPathComponent() == temporary,
              profile.lastPathComponent.hasPrefix("spaceo-browser-") else {
            return false
        }
        guard FileManager.default.fileExists(atPath: profile.path) else { return true }
        do {
            try FileManager.default.removeItem(at: profile)
            return true
        } catch {
            return false
        }
    }

    static func devToolsPort(in profile: URL) -> Int? {
        let marker = profile.appendingPathComponent("DevToolsActivePort")
        guard let contents = try? String(contentsOf: marker, encoding: .utf8),
              let firstLine = contents.split(whereSeparator: \.isNewline).first,
              let port = Int(firstLine),
              (1...65_535).contains(port) else {
            return nil
        }
        return port
    }

    private static func waitForDevToolsPort(
        in profile: URL,
        timeout: TimeInterval
    ) async -> Int? {
        let deadline = Date().addingTimeInterval(max(0.5, timeout))
        repeat {
            if let port = devToolsPort(in: profile) { return port }
            try? await Task.sleep(nanoseconds: 100_000_000)
        } while Date() < deadline
        return nil
    }

    /// Resolve a user-supplied string to an app bundle: a path, or a name like "TextEdit".
    public static func resolve(_ nameOrPath: String) -> URL? {
        let asPath = URL(fileURLWithPath: (nameOrPath as NSString).expandingTildeInPath)
        if FileManager.default.fileExists(atPath: asPath.path), asPath.pathExtension == "app" {
            return asPath
        }
        if let byID = NSWorkspace.shared.urlForApplication(withBundleIdentifier: nameOrPath) {
            return byID
        }
        let bare = nameOrPath.hasSuffix(".app") ? nameOrPath : nameOrPath + ".app"
        for directory in ["/System/Applications", "/Applications",
                          "/System/Applications/Utilities", "/Applications/Utilities",
                          NSHomeDirectory() + "/Applications"] {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(bare)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Is this bundle a Chromium derivative? Read from the bundle rather than a name list,
    /// so forks we have never heard of are still handled correctly.
    public static func isChromiumFamily(_ appURL: URL) -> Bool {
        guard let bundle = Bundle(url: appURL) else { return false }
        let identifier = bundle.bundleIdentifier ?? ""
        let known = ["com.google.Chrome", "org.chromium.Chromium", "com.microsoft.edgemac",
                     "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
                     "company.thebrowser.Browser"]
        if known.contains(where: { identifier.hasPrefix($0) }) { return true }
        // Every Chromium build ships this helper alongside the main executable.
        let helper = appURL.appendingPathComponent("Contents/Frameworks")
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: helper.path),
           entries.contains(where: { $0.contains("Chromium") || $0.contains("Chrome") }) {
            return true
        }
        return false
    }

    private static func runningInstances(of appURL: URL) -> Set<pid_t> {
        Set(NSWorkspace.shared.runningApplications
            .filter { $0.bundleURL?.standardizedFileURL == appURL.standardizedFileURL }
            .map(\.processIdentifier))
    }
}
