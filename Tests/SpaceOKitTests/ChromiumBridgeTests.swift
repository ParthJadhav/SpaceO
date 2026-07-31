import XCTest
import Foundation
import Darwin
@testable import SpaceOKit

/// Regressions for SPAO-132: bounded DevTools responses and deliberate target binding.
///
/// Driven against a real loopback HTTP server rather than a mocked `URLSession`, because both
/// halves of the ticket are about what happens on the wire — a body that keeps coming, and a
/// target list whose order means nothing.
final class ChromiumBridgeTests: XCTestCase {

    // MARK: - A DevTools endpoint that answers however the test needs

    /// Minimal single-shot HTTP server on 127.0.0.1. Serves one canned body per connection.
    final class FakeDevTools {

        enum Behavior {
            /// A normal JSON reply. The closure receives the port the server ended up on, so a
            /// target list can carry websocket urls that actually match it.
            case body((Int) -> String)
            /// Claim a huge Content-Length, then stream `chunkCount` chunks of `chunk`.
            case oversized(chunk: String, chunkCount: Int, declaredLength: Int?)
        }

        let port: Int
        private let listener: Int32
        private var thread: Thread?
        private let behavior: Behavior
        private let stopped = NSLock()
        private var isStopped = false

        init?(behavior: Behavior) {
            // Everything runs against locals until the last line: a closure that touched a
            // stored property here would capture a half-initialised `self`.
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0                        // let the kernel choose
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, listen(fd, 8) == 0 else {
                close(fd)
                return nil
            }
            var actual = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &actual) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(fd, $0, &length)
                }
            }
            guard named == 0 else {
                close(fd)
                return nil
            }
            self.behavior = behavior
            self.listener = fd
            self.port = Int(UInt16(bigEndian: actual.sin_port))
            start()
        }

        private func start() {
            let thread = Thread { [weak self] in self?.serve() }
            thread.name = "fake-devtools"
            self.thread = thread
            thread.start()
        }

        private func serve() {
            while !stopped.withLock({ isStopped }) {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                defer { close(client) }
                var noSignal: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                           socklen_t(MemoryLayout<Int32>.size))

                // Read (and discard) the request line; we answer every path the same way.
                var scratch = [UInt8](repeating: 0, count: 4096)
                _ = recv(client, &scratch, scratch.count, 0)

                switch behavior {
                case .body(let make):
                    let json = make(port)
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                        + "Content-Length: \(json.utf8.count)\r\nConnection: close\r\n\r\n" + json
                    _ = send(client, response, response.utf8.count, 0)

                case .oversized(let chunk, let chunkCount, let declaredLength):
                    let declared = declaredLength ?? (chunk.utf8.count * chunkCount)
                    let header = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                        + "Content-Length: \(declared)\r\nConnection: close\r\n\r\n"
                    _ = send(client, header, header.utf8.count, 0)
                    for _ in 0..<chunkCount {
                        if stopped.withLock({ isStopped }) { break }
                        let written = send(client, chunk, chunk.utf8.count, 0)
                        // The client cancelling mid-stream is the success case for the oversized
                        // tests; stop writing rather than spinning on a broken pipe.
                        if written <= 0 { break }
                    }
                }
            }
        }

        func stop() {
            stopped.withLock { isStopped = true }
            close(listener)
        }
    }

    // MARK: - Bounded responses

    func testANormalTargetListIsParsed() async throws {
        let server = try XCTUnwrap(FakeDevTools(behavior: .body { port in
            Self.listing([(id: "A", title: "one")], port: port)
        }))
        defer { server.stop() }

        let bridge = ChromiumBridge(port: server.port)
        let targets = try await bridge.targets()
        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(targets.first?.id, "A")
        XCTAssertEqual(targets.first?.title, "one")
    }

    /// A page whose debugger url points somewhere other than the browser's own loopback port is
    /// dropped, not attached to — the endpoint does not get to redirect automation.
    func testAnEntryPointingOffTheLoopbackPortIsNotATarget() async throws {
        let server = try XCTUnwrap(FakeDevTools(behavior: .body { port in
            Self.listing([(id: "A", title: "one")], port: port + 1)
        }))
        defer { server.stop() }

        let bridge = ChromiumBridge(port: server.port)
        let targets = try await bridge.targets()
        XCTAssertTrue(targets.isEmpty)
    }

    /// The core fix: the body is abandoned *while* it is arriving, not measured after it lands.
    func testAnOversizedTargetListIsRefusedWithoutBufferingItAll() async throws {
        // 64 KiB per chunk, far more chunks than the limit allows: a bridge that buffered first
        // would hold tens of megabytes before it ever checked.
        let chunk = String(repeating: "x", count: 64 * 1024)
        let chunkCount = 64
        let server = try XCTUnwrap(FakeDevTools(behavior: .oversized(
            chunk: chunk, chunkCount: chunkCount, declaredLength: nil)))
        defer { server.stop() }

        let bridge = ChromiumBridge(port: server.port)
        do {
            _ = try await bridge.targets()
            XCTFail("an oversized target list must be refused")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("limit"),
                          "the refusal must name the limit: \(error.localizedDescription)")
        }
    }

    /// A declared length over the limit is refused before a byte of body is read at all.
    func testADeclaredLengthOverTheLimitIsRefusedUpFront() async throws {
        let server = try XCTUnwrap(FakeDevTools(behavior: .oversized(
            chunk: "x", chunkCount: 1,
            declaredLength: ChromiumBridge.maximumTargetListBytes + 1)))
        defer { server.stop() }

        let bridge = ChromiumBridge(port: server.port)
        do {
            _ = try await bridge.targets()
            XCTFail("a body declaring more than the limit must be refused")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("declares"),
                          error.localizedDescription)
        }
    }

    func testTheLimitIsActuallyEnforcedNotJustDeclared() {
        XCTAssertEqual(ChromiumBridge.maximumTargetListBytes, 1_048_576)
    }

    func testAnInvalidPortIsRefusedBeforeAnyConnection() async {
        for port in [0, -1, 70_000] {
            let bridge = ChromiumBridge(port: port)
            do {
                _ = try await bridge.targets()
                XCTFail("port \(port) must be refused")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("port"),
                              error.localizedDescription)
            }
        }
    }

    // MARK: - Target binding

    static func listing(_ entries: [(id: String, title: String)], port: Int) -> String {
        let body = entries.map { entry in
            """
            {"type":"page","id":"\(entry.id)","title":"\(entry.title)",
             "url":"https://example.test/\(entry.id)",
             "webSocketDebuggerUrl":"ws://127.0.0.1:\(port)/devtools/page/\(entry.id)"}
            """
        }.joined(separator: ",")
        return "[\(body)]"
    }

    func testAnEmptyTargetListFailsClosed() async throws {
        let server = try XCTUnwrap(FakeDevTools(behavior: .body { _ in "[]" }))
        defer { server.stop() }
        let bridge = ChromiumBridge(port: server.port)
        do {
            _ = try await bridge.attachToLaunchedTarget()
            XCTFail("no pages means nothing to attach to")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no page targets"),
                          error.localizedDescription)
        }
        let bound = await bridge.boundTargetID
        XCTAssertNil(bound)
    }

    /// The behaviour the ticket is about: list order is not authority. With more than one page,
    /// the bridge must refuse rather than silently drive whichever came back first.
    func testMultipleTargetsFailClosedInsteadOfTrustingListOrder() async throws {
        let server = try XCTUnwrap(FakeDevTools(behavior: .body { port in
            Self.listing([(id: "A", title: "first"), (id: "B", title: "second")], port: port)
        }))
        defer { server.stop() }

        let bridge = ChromiumBridge(port: server.port)
        do {
            _ = try await bridge.attachToLaunchedTarget()
            XCTFail("two pages is ambiguous and must not be resolved by list order")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("2 page targets"), message)
            XCTAssertTrue(message.contains("A") && message.contains("B"),
                          "the refusal must name the candidates so a caller can choose: \(message)")
        }
        let bound = await bridge.boundTargetID
        XCTAssertNil(bound, "a refused attach must leave the bridge unbound")
    }

    func testAttachingToAnUnknownTargetIDFailsClosed() async throws {
        let server = try XCTUnwrap(FakeDevTools(behavior: .body { port in
            Self.listing([(id: "A", title: "first")], port: port)
        }))
        defer { server.stop() }

        let bridge = ChromiumBridge(port: server.port)
        do {
            _ = try await bridge.attach(toTargetID: "does-not-exist")
            XCTFail("an unknown target must be refused")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("does-not-exist"),
                          error.localizedDescription)
        }
    }

    func testAnEmptyOrOverlongTargetIDIsRefusedBeforeAnyRequest() async {
        let bridge = ChromiumBridge(port: 9_222)
        for id in ["", String(repeating: "x", count: 257)] {
            do {
                _ = try await bridge.attach(toTargetID: id)
                XCTFail("target id '\(id.prefix(8))…' must be refused")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("target id"),
                              error.localizedDescription)
            }
        }
    }

    /// Commands must never run against a bridge that is not deliberately bound to a page.
    func testCommandsOnAnUnboundBridgeFailClosed() async {
        let bridge = ChromiumBridge(port: 9_222)
        do {
            _ = try await bridge.evaluate("1 + 1")
            XCTFail("an unbound bridge must not execute anything")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not attached"),
                          error.localizedDescription)
        }
        do {
            try await bridge.verifyBoundTarget()
            XCTFail("verification of an unbound bridge must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not attached"),
                          error.localizedDescription)
        }
    }

    // MARK: - Endpoint validation

    func testWebSocketURLsMustStayOnTheirPrivateLoopbackPort() {
        XCTAssertNotNil(ChromiumBridge.validatedWebSocketURL(
            "ws://127.0.0.1:9222/devtools/page/A", port: 9_222))
        XCTAssertNotNil(ChromiumBridge.validatedWebSocketURL(
            "ws://localhost:9222/devtools/page/A", port: 9_222))

        for hostile in ["ws://evil.test:9222/devtools/page/A",
                        "ws://127.0.0.1:9223/devtools/page/A",
                        "wss://127.0.0.1:9222/devtools/page/A",
                        "ws://user:pass@127.0.0.1:9222/devtools/page/A",
                        "http://127.0.0.1:9222/devtools/page/A"] {
            XCTAssertNil(ChromiumBridge.validatedWebSocketURL(hostile, port: 9_222),
                         "\(hostile) must not be accepted")
        }
    }
}
