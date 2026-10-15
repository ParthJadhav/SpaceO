import CoreGraphics
import Foundation

/// A bounded set of virtual display identities (RA-057).
///
/// macOS keeps per-identity state that nothing ever removes: a ColorSync device registration and a
/// factory `.icc` profile per (vendor, product, serial), plus WindowServer display mappings.
/// ColorSync re-reads its whole device registry for every display-info request WindowServer makes,
/// so a fresh random serial per attachment — SpaceO's original choice — grew that registry with
/// every display ever created (760 of 766 display profiles on one development Mac) until each
/// request took ~85 ms, ColorSync saturated, WindowServer exhausted its dispatch threads and the
/// watchdog killed the login session.
///
/// Identities are now a pure function of the requested geometry, a slot and a generation. A slot
/// is reused once no online display and no live object in this process still holds it, so a host
/// accumulates at most one identity per (geometry, slot, generation). The random serial existed
/// because a reused identity once restored a saved configuration that left the display online but
/// inactive, without its own Space; publication rejects such a display, and `rotate` then retires
/// that identity for good by advancing the slot's persisted generation.
final class DisplayIdentityAllocator: @unchecked Sendable {
    struct Identity: Equatable, Sendable {
        let key: String
        let slot: Int
        let generation: Int
        let serial: UInt32
    }

    static let shared = DisplayIdentityAllocator()
    static let slotCount = 32
    /// Persisted generations beyond this many keys are not recorded; bounded file, bounded growth.
    static let maximumPersistedKeys = 512

    /// Busy while a claim awaits its display (`pending`) or while that display object is alive.
    private final class Holder {
        var pending = true
        weak var value: AnyObject?
        var busy: Bool { pending || value != nil }
    }

    private let lock = NSLock()
    private let path: String?
    private var generations: [String: Int]?
    private var holders: [UInt32: Holder] = [:]

    init(path: String? = DisplayIdentityAllocator.defaultPath) {
        self.path = path
    }

    static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SpaceO/display-identities.json").path
    }

    static func key(width: UInt32, height: UInt32, hiDPI: Bool) -> String {
        "\(width)x\(height)@\(hiDPI ? 2 : 1)"
    }

    /// FNV-1a over a versioned description; never zero, which the descriptor treats as unset.
    static func serial(key: String, slot: Int, generation: Int) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in "spaceo-display-v1|\(key)|\(slot)|\(generation)".utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return hash == 0 ? 1 : hash
    }

    /// The lowest slot whose identity is neither online (`onlineSerials`, any process) nor held by a
    /// live display object of this process. Nil only when every slot is busy.
    func claim(width: UInt32, height: UInt32, hiDPI: Bool,
               onlineSerials: Set<UInt32>) -> Identity? {
        let key = Self.key(width: width, height: height, hiDPI: hiDPI)
        return lock.withLock {
            let generations = loadedGenerations()
            for slot in 0..<Self.slotCount {
                let generation = generations["\(key)/\(slot)"] ?? 0
                let serial = Self.serial(key: key, slot: slot, generation: generation)
                guard !onlineSerials.contains(serial), holders[serial]?.busy != true else { continue }
                holders[serial] = Holder()
                return Identity(key: key, slot: slot, generation: generation, serial: serial)
            }
            return nil
        }
    }

    /// Tie the claim to the display object; the slot frees itself when that object is released.
    func bind(_ identity: Identity, to display: AnyObject) {
        lock.withLock {
            let holder = Holder()
            holder.value = display
            holder.pending = false
            holders[identity.serial] = holder
        }
    }

    /// A claim whose display was never created.
    func abandon(_ identity: Identity) {
        lock.withLock {
            if let holder = holders[identity.serial], holder.pending { holders.removeValue(forKey: identity.serial) }
        }
    }

    /// This identity came back unusable (inactive, mirrored, without its own Space): never use it
    /// again. The new generation is persisted before the caller reports the failure.
    @discardableResult
    func rotate(_ identity: Identity) -> Bool {
        lock.withLock {
            var generations = loadedGenerations()
            let slotKey = "\(identity.key)/\(identity.slot)"
            guard (generations[slotKey] ?? 0) == identity.generation else { return true }
            guard generations[slotKey] != nil || generations.count < Self.maximumPersistedKeys else {
                return false
            }
            generations[slotKey] = identity.generation + 1
            self.generations = generations
            return persist(generations)
        }
    }

    func generation(key: String, slot: Int) -> Int {
        lock.withLock { loadedGenerations()["\(key)/\(slot)"] ?? 0 }
    }

    // MARK: - Persistence (caller holds `lock`)

    private struct Stored: Codable {
        var version: Int
        var generations: [String: Int]
    }

    private func loadedGenerations() -> [String: Int] {
        if let generations { return generations }
        var loaded: [String: Int] = [:]
        if let path, let data = FileManager.default.contents(atPath: path), data.count <= 262_144,
           let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.version == 1 {
            // Ignore malformed values: a negative or absurd generation is not a usable identity.
            loaded = stored.generations.filter { $0.value >= 0 && $0.value < 1_000_000 }
        }
        generations = loaded
        return loaded
    }

    private func persist(_ generations: [String: Int]) -> Bool {
        guard let path else { return true }
        let url = URL(fileURLWithPath: path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Stored(version: 1, generations: generations)) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return true
        } catch {
            return false
        }
    }
}
