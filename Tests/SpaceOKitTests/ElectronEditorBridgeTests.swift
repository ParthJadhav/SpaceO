import Darwin
import Foundation
import XCTest
@testable import SpaceOKit

final class ElectronEditorBridgeTests: XCTestCase {
    final class RawUnixServer: @unchecked Sendable {
        let path: String
        private let listener: Int32
        private let responses: [String]
        private let stateLock = NSLock()
        private var capturedRequests: [String] = []
        private var stopped = false
        private var thread: Thread?

        var requests: [String] {
            stateLock.withLock { capturedRequests }
        }

        init?(responses: [String]) {
            self.path = "/tmp/so-electron-\(UUID().uuidString.prefix(10)).sock"
            self.responses = responses
            listener = socket(AF_UNIX, SOCK_STREAM, 0)
            guard listener >= 0 else { return nil }

            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard path.utf8.count < capacity else {
                close(listener)
                return nil
            }
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    _ = strcpy($0, path)
                }
            }
            let didBind = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(
                        listener,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard didBind == 0, listen(listener, 4) == 0,
                  chmod(path, 0o600) == 0 else {
                close(listener)
                unlink(path)
                return nil
            }
        }

        func start() {
            let worker = Thread { [self] in
                for response in responses {
                    let client = accept(listener, nil, nil)
                    guard client >= 0 else { return }
                    if let request = Transport.readLine(
                        from: client,
                        maximumBytes: 16 * 1_024) {
                        stateLock.withLock { capturedRequests.append(request) }
                    }
                    var payload = Data((response + "\n").utf8)
                    payload.withUnsafeMutableBytes { bytes in
                        guard let base = bytes.baseAddress else { return }
                        _ = Foundation.write(client, base, bytes.count)
                    }
                    close(client)
                }
            }
            thread = worker
            worker.start()
        }

        func stop() {
            let shouldStop = stateLock.withLock {
                guard !stopped else { return false }
                stopped = true
                return true
            }
            guard shouldStop else { return }
            shutdown(listener, SHUT_RDWR)
            close(listener)
            thread?.cancel()
            unlink(path)
        }

        deinit { stop() }
    }

    func testVSCodeElectronDetectionRequiresTheActualBundleShape() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spaceo-vscode-shape-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: root) }
        let framework = root.appendingPathComponent(
            "Contents/Frameworks/Electron Framework.framework")
        let appResources = root.appendingPathComponent("Contents/Resources/app")
        try FileManager.default.createDirectory(
            at: framework, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: appResources.appendingPathComponent("out"),
            withIntermediateDirectories: true)
        try "".write(
            to: appResources.appendingPathComponent("out/cli.js"),
            atomically: true,
            encoding: .utf8)
        try "{}".write(
            to: appResources.appendingPathComponent("product.json"),
            atomically: true,
            encoding: .utf8)

        XCTAssertTrue(AppLauncher.isVSCodeElectronFamily(root))
        try FileManager.default.removeItem(
            at: appResources.appendingPathComponent("out/cli.js"))
        XCTAssertFalse(
            AppLauncher.isVSCodeElectronFamily(root),
            "an arbitrary Electron shell must not receive a VS Code extension")
    }

    func testEmbeddedControllerIsBoundedAuthenticatedAndEffectAware() {
        let source = ElectronControlAssets.extensionJavaScript
        XCTAssertTrue(source.contains("MAX_REQUEST_BYTES = 16 * 1024"))
        XCTAssertTrue(source.contains("timingSafeEqual"))
        XCTAssertTrue(source.contains("visibleRanges"))
        XCTAssertTrue(source.contains("visibleEditors.length !== 1"))
        XCTAssertTrue(source.contains("visible range did not change"))
        XCTAssertTrue(source.contains(#"server.on("error""#))
        XCTAssertFalse(source.contains("app.activate"))
        XCTAssertFalse(source.contains("showInactive"))
    }

    func testBridgeRequiresAndReturnsARealVisibleRangeChange() async throws {
        let server = try XCTUnwrap(RawUnixServer(responses: [
            #"{"ok":true,"document":"file:///tmp/a.txt","visible":[[0,0,40,0]]}"#,
            #"{"ok":true,"changed":true,"before":[[0,0,40,0]],"after":[[80,0,120,0]],"document":"file:///tmp/a.txt"}"#,
        ]))
        server.start()
        defer { server.stop() }

        let bridge = ElectronEditorBridge(
            endpoint: ElectronControlEndpoint(
                socket: URL(fileURLWithPath: server.path),
                token: "test-secret"))
        let document = try await bridge.ping()
        XCTAssertEqual(document, "file:///tmp/a.txt")
        let effect = try await bridge.scroll(deltaY: -1_600, pages: 4)
        XCTAssertEqual(effect.before, [[0, 0, 40, 0]])
        XCTAssertEqual(effect.after, [[80, 0, 120, 0]])
        XCTAssertNotEqual(effect.before, effect.after)
        XCTAssertTrue(server.requests.allSatisfy { $0.contains("test-secret") })
    }

    func testBridgeRejectsASuccessResponseWithoutAnEffect() async throws {
        let server = try XCTUnwrap(RawUnixServer(responses: [
            #"{"ok":true,"changed":false,"before":[[0,0,40,0]],"after":[[0,0,40,0]],"document":"file:///tmp/a.txt"}"#,
        ]))
        server.start()
        defer { server.stop() }
        let bridge = ElectronEditorBridge(
            endpoint: ElectronControlEndpoint(
                socket: URL(fileURLWithPath: server.path),
                token: "test-secret"))
        do {
            _ = try await bridge.scroll(deltaY: -800, pages: 2)
            XCTFail("a successful return with no visible-range change must fail")
        } catch {
            XCTAssertTrue("\(error)".contains("observable visible-range change"))
        }
    }
}
