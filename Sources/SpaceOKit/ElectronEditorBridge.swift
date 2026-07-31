import Darwin
import Foundation

/// Semantic, focus-free control channel for VS Code-family Electron renderers.
///
/// Cursor/VS Code intentionally ignore synthetic background wheel events, and their editor
/// scrollbar is not settable through macOS Accessibility. A private extension loaded only into
/// the agent-owned instance can invoke the editor's own scroll command instead. Every response
/// includes the visible ranges before and after; an accepted command with no range change is an
/// error, never a successful-return/no-effect result.
public actor ElectronEditorBridge {
    struct ControlRequest: Codable, Sendable {
        let version: Int
        let token: String
        let command: String
        let direction: String?
        let pages: Int?
    }

    struct ControlResponse: Codable, Sendable, Equatable {
        let ok: Bool
        let changed: Bool?
        let before: [[Int]]?
        let after: [[Int]]?
        let visible: [[Int]]?
        let document: String?
        let error: String?
    }

    public struct ScrollEffect: Sendable, Equatable {
        public let document: String
        public let before: [[Int]]
        public let after: [[Int]]
    }

    private let endpoint: ElectronControlEndpoint

    public init(endpoint: ElectronControlEndpoint) {
        self.endpoint = endpoint
    }

    public func waitUntilReady(timeout: TimeInterval = 10) async -> Bool {
        guard timeout.isFinite, timeout > 0, timeout <= 60 else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if (try? await ping()) != nil { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        } while Date() < deadline
        return false
    }

    @discardableResult
    public func ping() async throws -> String {
        let response = try await exchange(
            ControlRequest(
                version: 1,
                token: endpoint.token,
                command: "ping",
                direction: nil,
                pages: nil))
        guard response.ok, let document = response.document,
              !document.isEmpty, response.visible != nil else {
            throw SpaceOError.unsupportedTarget(
                response.error ?? "Electron editor controller is not ready")
        }
        return document
    }

    @discardableResult
    public func scroll(deltaY: Int, pages: Int) async throws -> ScrollEffect {
        guard deltaY != 0 else {
            throw SpaceOError.badRequest("Electron editor scroll needs a non-zero vertical delta")
        }
        guard (1...100).contains(pages) else {
            throw SpaceOError.badRequest("scroll ticks must be from 1 through 100")
        }
        let response = try await exchange(
            ControlRequest(
                version: 1,
                token: endpoint.token,
                command: "scroll",
                direction: deltaY < 0 ? "down" : "up",
                pages: pages))
        guard response.ok else {
            throw SpaceOError.unsupportedTarget(
                response.error ?? "Electron editor rejected the semantic scroll")
        }
        guard response.changed == true,
              let before = response.before,
              let after = response.after,
              before != after,
              let document = response.document,
              !document.isEmpty else {
            throw SpaceOError.unsupportedTarget(
                "Electron editor returned without an observable visible-range change")
        }
        return ScrollEffect(document: document, before: before, after: after)
    }

    private func exchange(_ request: ControlRequest) async throws -> ControlResponse {
        try validateSocket()
        let payload = try Wire.encoder.encode(request)
        let path = endpoint.socket.path
        let responseData = try await Task.detached(priority: .userInitiated) {
            try Transport.sendLinePayload(
                payload,
                to: path,
                timeout: 2,
                maximumRequestBytes: 16 * 1_024,
                maximumResponseBytes: 16 * 1_024)
        }.value
        do {
            return try Wire.decoder.decode(ControlResponse.self, from: responseData)
        } catch {
            throw SpaceOError.unsupportedTarget(
                "Electron editor controller returned a malformed response")
        }
    }

    private func validateSocket() throws {
        let path = endpoint.socket.path
        var metadata = stat()
        guard lstat(path, &metadata) == 0,
              metadata.st_uid == geteuid(),
              (metadata.st_mode & S_IFMT) == S_IFSOCK,
              (metadata.st_mode & 0o077) == 0 else {
            throw SpaceOError.unsupportedTarget(
                "Electron editor controller socket is absent or has unsafe ownership/permissions")
        }
    }
}
