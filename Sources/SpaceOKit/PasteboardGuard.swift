import Foundation
import AppKit

/// The general pasteboard is a shared singleton and agents *will* clobber it.
///
/// Losing what you copied thirty seconds ago is exactly the kind of small, constant theft
/// SpaceO exists to prevent, so any agent action that might copy or cut runs inside a
/// snapshot/restore bracket.
public enum PasteboardGuard {

    /// A copy of the general pasteboard's contents, sufficient to put back.
    public struct Snapshot {
        let items: [[String: Data]]
        let changeCount: Int

        public var isEmpty: Bool { items.isEmpty }
        public var typeCount: Int { items.reduce(0) { $0 + $1.count } }
    }

    public static func snapshot() -> Snapshot {
        snapshot(from: .general)
    }

    public static func snapshot(from pasteboard: NSPasteboard) -> Snapshot {
        var captured: [[String: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var payload: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { payload[type.rawValue] = data }
            }
            if !payload.isEmpty { captured.append(payload) }
        }
        return Snapshot(items: captured, changeCount: pasteboard.changeCount)
    }

    /// Put a snapshot back, unless the clipboard already holds exactly this content.
    ///
    /// The skip test compares actual contents rather than `changeCount`: a write that is not
    /// preceded by `clearContents()` mutates the pasteboard *without* bumping the counter, so
    /// trusting the counter would silently skip restores that were needed.
    @discardableResult
    public static func restore(_ snapshot: Snapshot) -> Bool {
        restore(snapshot, to: .general)
    }

    @discardableResult
    public static func restore(_ snapshot: Snapshot, to pasteboard: NSPasteboard) -> Bool {
        guard snapshot.items != Self.snapshot(from: pasteboard).items else { return false }

        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return true }

        let restored = snapshot.items.map { payload -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in payload {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        return pasteboard.writeObjects(restored)
    }

    /// Run `body` with the user's clipboard preserved, whatever the agent does inside.
    public static func preserving<T>(_ body: () throws -> T) rethrows -> T {
        let saved = snapshot()
        defer { restore(saved) }
        return try body()
    }

    public static func preserving<T>(
        pasteboard: NSPasteboard,
        _ body: () throws -> T
    ) rethrows -> T {
        let saved = snapshot(from: pasteboard)
        defer { restore(saved, to: pasteboard) }
        return try body()
    }

    public static func preserving<T>(_ body: () async throws -> T) async rethrows -> T {
        let saved = snapshot()
        defer { restore(saved) }
        return try await body()
    }
}
