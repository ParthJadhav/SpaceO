import Foundation
import AppKit
import CoreGraphics

/// Private, per-launch control endpoint for a VS Code-family Electron renderer.
///
/// The token is intentionally live-memory-only. The root is persisted separately so crash
/// recovery can remove it after terminating an owned survivor without writing the credential
/// to the session journal.
public struct ElectronControlEndpoint: Sendable, Equatable {
    public let socket: URL
    public let token: String
}

/// An application SpaceO started (or adopted) on behalf of an agent.
public struct LaunchedApp: Sendable, Equatable {
    public let pid: pid_t
    /// PID plus kernel start time. Every action that could disturb a process — force-terminate,
    /// capture, input delivery — checks this rather than the PID alone, so a session that
    /// outlived its app cannot act on whatever inherited its number.
    public let identity: ProcessIdentity
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
    /// Semantic renderer channel for a VS Code-family Electron app SpaceO launched.
    public var electronControl: ElectronControlEndpoint? = nil
    /// Private extension/socket root. Unlike the token, this is safe to persist for cleanup.
    public var temporaryControlRoot: URL? = nil
}

/// Starts applications without activating them.
///
/// `activates = false` is what keeps the menu bar with the user. Combined with immediate
/// relocation onto the stage, the app never meaningfully appears on the user's screen.
public enum AppLauncher {

    private struct PreparedElectronControl {
        let root: URL
        let extensionsDirectory: URL
        let endpoint: ElectronControlEndpoint
    }

    /// Launch `appURL` (optionally opening `files`) and place all its windows in `region`.
    ///
    /// Requests a separate process and **refuses** application substitution. If macOS hands back
    /// a process that was already running, that process belongs to the user: relocating its
    /// windows would be SpaceO rearranging someone's desktop, which is the one thing this project
    /// promises not to do. The launch fails instead, before anything moves.
    public nonisolated(nonsending) static func launch(
        appURL: URL,
        opening files: [URL] = [],
        into region: CGRect,
        timeout: TimeInterval = 15,
        onMaterialized: (LaunchedApp) async throws -> Void = { _ in }
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
        var electronControl: ElectronControlEndpoint?
        var temporaryControlRoot: URL?
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
        } else if isVSCodeElectronFamily(appURL) {
            let prepared: PreparedElectronControl
            do {
                prepared = try prepareElectronControl()
            } catch {
                throw SpaceOError.launchFailed(
                    "could not prepare the private Electron controller: "
                        + error.localizedDescription)
            }
            configuration.arguments = [
                "--extensions-dir=\(prepared.extensionsDirectory.path)",
            ]
            var environment = ProcessInfo.processInfo.environment
            environment[ElectronControlAssets.socketEnvironmentKey] =
                prepared.endpoint.socket.path
            environment[ElectronControlAssets.tokenEnvironmentKey] =
                prepared.endpoint.token
            configuration.environment = environment
            electronControl = prepared.endpoint
            temporaryControlRoot = prepared.root
        }

        // Two independent tests for "this process is not ours", because the PID snapshot alone
        // has a time-of-check/time-of-use hole: a user process that opens between the snapshot
        // and `openApplication` is absent from `existing` and would be misread as ours. A start
        // time from before we asked cannot be a process our request created, whatever the
        // snapshot says.
        let existing = runningInstances(of: appURL)
        let requestedAtMicroseconds = UInt64(max(0, Date().timeIntervalSince1970 * 1_000_000))
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
            removeTemporaryControlRoot(at: temporaryControlRoot)
            throw SpaceOError.launchFailed("\(appURL.lastPathComponent): \(error.localizedDescription)")
        }

        let pid = runningApp.processIdentifier
        guard let identity = ProcessIdentity.current(of: pid) else {
            removeTemporaryProfile(at: temporaryProfile)
            removeTemporaryControlRoot(at: temporaryControlRoot)
            throw SpaceOError.launchFailed(
                "\(appURL.lastPathComponent) exited before SpaceO could identify it")
        }

        // Refuse the substituted process. Note the asymmetry in how the two signals are combined:
        // a *precise* start time predating the request is proof of a pre-existing process, while
        // an imprecise one can only fall back to the racy snapshot. Either says "not ours".
        let predatesRequest = identity.isPrecise
            && identity.startedAtMicroseconds < requestedAtMicroseconds
        if existing.contains(pid) || predatesRequest {
            removeTemporaryProfile(at: temporaryProfile)
            removeTemporaryControlRoot(at: temporaryControlRoot)
            throw SpaceOError.launchFailed(
                "\(appURL.lastPathComponent) is already running as pid \(pid); macOS reused that "
                + "process instead of starting a new one. SpaceO will not move a running app's "
                + "windows — quit it first, or adopt it deliberately with `spaceo adopt --pid \(pid)`")
        }

        var app = LaunchedApp(
            pid: pid,
            identity: identity,
            bundleIdentifier: runningApp.bundleIdentifier,
            name: runningApp.localizedName
                ?? appURL.deletingPathExtension().lastPathComponent,
            url: appURL,
            startedByUs: true,
            devToolsPort: nil,
            temporaryProfile: temporaryProfile,
            electronControl: electronControl,
            temporaryControlRoot: temporaryControlRoot)

        do {
            // This callback is the WAL commit boundary. It runs immediately after SpaceO has an
            // exact process identity, before DevTools discovery, window waits, placement, or any
            // other potentially long operation. The session claims/registers the process and
            // the daemon persists that identity before launch work may continue.
            try await onMaterialized(app)
            if let profile = temporaryProfile {
                devToolsPort = await waitForDevToolsPort(
                    in: profile,
                    timeout: min(timeout, 10))
                app.devToolsPort = devToolsPort
            }
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

    /// Describe an already-running process well enough to claim it, without touching it.
    ///
    /// Separate from `adopt` so a caller can take exclusive ownership *before* the first window
    /// moves. Adoption that mutates first and checks afterwards is how two sessions ended up
    /// fighting over one process.
    public static func describe(pid: pid_t) throws -> LaunchedApp {
        guard pid > 0 else {
            throw SpaceOError.badRequest("adopt needs a positive pid")
        }
        guard let running = NSRunningApplication(processIdentifier: pid),
              let identity = ProcessIdentity.current(of: pid) else {
            throw SpaceOError.launchFailed("no running application with pid \(pid)")
        }
        return LaunchedApp(pid: pid,
                           identity: identity,
                           bundleIdentifier: running.bundleIdentifier,
                           name: running.localizedName ?? "pid \(pid)",
                           url: running.bundleURL ?? URL(fileURLWithPath: "/"),
                           startedByUs: false,
                           devToolsPort: nil,
                           temporaryProfile: nil)
    }

    /// Move an already-described process's windows into `region`.
    public static func place(_ app: LaunchedApp, into region: CGRect) throws -> [WindowRef] {
        try WindowPlacement.validate(frame: region)
        guard app.identity.isAlive else {
            throw SpaceOError.launchFailed(
                "\(app.name) (\(app.identity)) exited before its windows could be placed")
        }
        return try WindowPlacement.placeAll(of: app.pid, into: region)
    }

    /// Adopt an already-running process into a stage without launching anything.
    public static func adopt(pid: pid_t, into region: CGRect) throws -> (app: LaunchedApp, windows: [WindowRef]) {
        try WindowPlacement.validate(frame: region)
        let app = try describe(pid: pid)
        return (app, try place(app, into: region))
    }

    /// Ask an app to quit politely. Never force-kills apps we did not start.
    ///
    /// Both branches re-check the identity first: a session that has been alive for hours may be
    /// holding a PID the kernel has since handed to something the user cares about, and
    /// "terminate whatever has this number now" is not a teardown, it is a bug with a body count.
    public static func quit(_ app: LaunchedApp, force: Bool = false) {
        guard app.identity.isAlive,
              let running = NSRunningApplication(processIdentifier: app.pid) else { return }
        if force && app.startedByUs && app.identity.isPrecise {
            running.forceTerminate()
        } else {
            running.terminate()
        }
    }

    /// Remove private browser/Electron control resources after the process is gone.
    ///
    /// The parent and prefix checks are deliberate: cleanup must never turn an unexpected path
    /// into a recursive delete outside SpaceO's own temporary directory.
    @discardableResult
    public static func cleanupTemporaryProfile(for app: LaunchedApp) -> Bool {
        guard !app.identity.isAlive else { return false }
        let removedProfile = removeTemporaryProfile(at: app.temporaryProfile)
        let removedControl = removeTemporaryControlRoot(at: app.temporaryControlRoot)
        return removedProfile && removedControl
    }

    /// A force-termination request is asynchronous. Retain cleanup responsibility briefly
    /// instead of deleting live process state or forgetting private directories forever.
    public static func cleanupTemporaryProfileEventually(for app: LaunchedApp) {
        guard app.temporaryProfile != nil || app.temporaryControlRoot != nil else { return }
        guard !cleanupTemporaryProfile(for: app) else { return }
        scheduleTemporaryResourceCleanup(
            identity: app.identity,
            profile: app.temporaryProfile,
            controlRoot: app.temporaryControlRoot)
    }

    private static func scheduleTemporaryResourceCleanup(
        identity: ProcessIdentity,
        profile: URL?,
        controlRoot: URL?
    ) {
        Task.detached(priority: .utility) {
            for _ in 0..<300 {
                guard identity.isAlive else {
                    _ = removeTemporaryProfile(at: profile)
                    _ = removeTemporaryControlRoot(at: controlRoot)
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

    @discardableResult
    static func removeTemporaryControlRoot(at candidate: URL?) -> Bool {
        guard let candidate else { return true }
        let root = candidate.standardizedFileURL
        let temporary = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .standardizedFileURL
        guard root.deletingLastPathComponent() == temporary,
              root.lastPathComponent.hasPrefix("spaceo-e-") else {
            return false
        }
        guard FileManager.default.fileExists(atPath: root.path) else { return true }
        do {
            try FileManager.default.removeItem(at: root)
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

    /// VS Code-family Electron bundles have a stable semantic extension API that can scroll an
    /// editor without synthesising input or activating the application.
    ///
    /// Do not classify arbitrary Electron shells here: loading a VS Code extension into an app
    /// that merely happens to ship Electron would be both ineffective and an unsafe assumption.
    public static func isVSCodeElectronFamily(_ appURL: URL) -> Bool {
        let resources = appURL.appendingPathComponent("Contents/Resources/app")
        let framework = appURL.appendingPathComponent(
            "Contents/Frameworks/Electron Framework.framework")
        return FileManager.default.fileExists(atPath: framework.path)
            && FileManager.default.fileExists(
                atPath: resources.appendingPathComponent("out/cli.js").path)
            && FileManager.default.fileExists(
                atPath: resources.appendingPathComponent("product.json").path)
    }

    private static func prepareElectronControl() throws -> PreparedElectronControl {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            .prefix(16)
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(
                "spaceo-e-\(getpid())-\(suffix)",
                isDirectory: true)
        let extensions = root.appendingPathComponent("extensions", isDirectory: true)
        let extensionDirectory = extensions.appendingPathComponent(
            ElectronControlAssets.extensionDirectoryName,
            isDirectory: true)
        let socket = root.appendingPathComponent("control.sock")
        guard socket.path.utf8.count < 100 else {
            throw SpaceOError.launchFailed("private Electron control path is too long")
        }

        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(
                at: extensionDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let package = extensionDirectory.appendingPathComponent("package.json")
            let script = extensionDirectory.appendingPathComponent("extension.js")
            try ElectronControlAssets.packageJSON.write(
                to: package, atomically: true, encoding: .utf8)
            try ElectronControlAssets.extensionJavaScript.write(
                to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: package.path)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: script.path)
        } catch {
            _ = removeTemporaryControlRoot(at: root)
            throw error
        }

        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        return PreparedElectronControl(
            root: root,
            extensionsDirectory: extensions,
            endpoint: ElectronControlEndpoint(socket: socket, token: token))
    }

    private static func runningInstances(of appURL: URL) -> Set<pid_t> {
        Set(NSWorkspace.shared.runningApplications
            .filter { $0.bundleURL?.standardizedFileURL == appURL.standardizedFileURL }
            .map(\.processIdentifier))
    }
}
