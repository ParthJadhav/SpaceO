import ApplicationServices
import Foundation

/// Owner-run removal of the ColorSync state that per-attachment display identities left behind
/// (RA-057): `spaceo safety clean-display-identities`.
///
/// Each identity left two layers. Its factory profile is a file; its device registration lives in
/// ColorSync's any-user registry, survives deleting the profile and rebooting, and is what
/// ColorSync re-reads for every display request. `ColorSyncUnregisterDevice` reports success to a
/// non-root caller while removing nothing, so applying requires root, and success is judged only
/// by a fresh enumeration afterwards. Only registrations whose profile names SpaceO's vendor and
/// product are touched; physical displays, Sidecar and other virtual-display tools are left alone.
public enum DisplayIdentityCleanup {
    public struct Registration: Sendable, Equatable {
        public var deviceClass: String
        public var deviceID: String
        /// Nil when ColorSync lists no readable profile for the device.
        public var profilePath: String?
    }

    public struct Plan: Sendable, Equatable {
        public var registrations: [Registration]
        /// SpaceO profile files, whether or not a registration still refers to them.
        public var profilePaths: [String]
        public var unattributedWithoutProfile: Int
    }

    public struct Outcome: Sendable, Equatable {
        public var plan: Plan
        public var backup: String
        public var unregistered: Int
        public var remainingRegistrations: Int
        public var movedProfiles: Int
        public var confirmed: Bool { remainingRegistrations == 0 }
    }

    public struct Environment {
        public var registrations: () -> [Registration]
        public var unregister: (Registration) -> Void
        public var profileDirectory: String
        public var registryPath: String
        public var isRoot: () -> Bool
        public var spaceODisplayOnline: () throws -> Bool

        public static let live = Environment(
            registrations: DisplayIdentityCleanup.liveRegistrations,
            unregister: DisplayIdentityCleanup.liveUnregister,
            profileDirectory: DisplayIdentityResidue.profilesDirectory,
            registryPath: DisplayIdentityResidue.registryPath,
            isRoot: { geteuid() == 0 },
            spaceODisplayOnline: { try Stage.checkedOnlineDisplayIDs().contains(where: Stage.isSpaceODisplay) })
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case requiresRoot
        case spaceODisplayOnline
        case backupFailed(String)

        public var errorDescription: String? {
            switch self {
            case .requiresRoot:
                return "ColorSync ignores unregistration from a normal account; rerun with sudo"
            case .spaceODisplayOnline:
                return "a SpaceO display is online; stop every SpaceO daemon and Viewer first"
            case .backupFailed(let reason):
                return "nothing was removed: the backup failed (\(reason))"
            }
        }
    }

    static func isSpaceOProfile(_ path: String) -> Bool {
        guard let data = try? BoundedRegularFile.read(URL(fileURLWithPath: path),
                                                      maximumBytes: DisplayIdentityResidue.maximumProfileBytes),
              let model = DisplayIdentityResidue.displayModel(profile: data) else { return false }
        return model.vendor == 0x1AF2 && model.product == 0x0001
    }

    public static func plan(_ environment: Environment = .live) -> Plan {
        // ColorSync lists a device once per profile; a device is SpaceO's when a profile says so.
        var registrations: [Registration] = []
        var spaceO = Set<String>(), profiled = Set<String>(), devices = Set<String>()
        for registration in environment.registrations() {
            devices.insert(registration.deviceID)
            guard let path = registration.profilePath else { continue }
            profiled.insert(registration.deviceID)
            if isSpaceOProfile(path), spaceO.insert(registration.deviceID).inserted {
                registrations.append(registration)
            }
        }
        let unattributed = devices.subtracting(profiled).count
        let names = (try? FileManager.default.contentsOfDirectory(atPath: environment.profileDirectory)) ?? []
        let profiles = names.filter { $0.hasSuffix(".icc") }.sorted()
            .prefix(DisplayIdentityResidue.maximumProfiles)
            .map { URL(fileURLWithPath: environment.profileDirectory).appendingPathComponent($0).path }
            .filter(isSpaceOProfile)
        return Plan(registrations: registrations, profilePaths: profiles, unattributedWithoutProfile: unattributed)
    }

    /// Back up, unregister, verify, then move the profiles into the backup. A registration that is
    /// still listed afterwards keeps its profile in place and is reported, never assumed removed.
    public static func apply(_ environment: Environment = .live, backupRoot: String,
                             now: Date = Date()) throws -> Outcome {
        guard environment.isRoot() else { throw Failure.requiresRoot }
        guard try !environment.spaceODisplayOnline() else { throw Failure.spaceODisplayOnline }
        let plan = Self.plan(environment)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: now)
        let backup = URL(fileURLWithPath: backupRoot).appendingPathComponent("colorsync-\(stamp)")
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: backup.appendingPathComponent("Profiles"),
                                        withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            if manager.fileExists(atPath: environment.registryPath) {
                try manager.copyItem(atPath: environment.registryPath,
                                     toPath: backup.appendingPathComponent("com.apple.colorsync.devices").path)
            }
            for path in plan.profilePaths {
                let name = URL(fileURLWithPath: path).lastPathComponent
                try manager.copyItem(atPath: path, toPath: backup.appendingPathComponent("Profiles/\(name)").path)
            }
        } catch {
            throw Failure.backupFailed(error.localizedDescription)
        }

        for registration in plan.registrations { environment.unregister(registration) }
        let remaining = Set(Self.plan(environment).registrations.map(\.deviceID))

        // A profile still referenced by a surviving registration stays; ColorSync would recreate it.
        let keep = Set(plan.registrations.filter { remaining.contains($0.deviceID) }.compactMap(\.profilePath))
        var moved = 0
        for path in plan.profilePaths where !keep.contains(path) {
            if (try? manager.removeItem(atPath: path)) != nil { moved += 1 }
        }
        return Outcome(plan: plan, backup: backup.path,
                       unregistered: plan.registrations.count - remaining.count,
                       remainingRegistrations: remaining.count, movedProfiles: moved)
    }

    // MARK: - ColorSync

    private final class Collector {
        var registrations: [Registration] = []
    }

    static func liveRegistrations() -> [Registration] {
        let collector = Collector()
        let context = Unmanaged.passUnretained(collector).toOpaque()
        ColorSyncIterateDeviceProfiles({ info, context in
            guard let info = info as? [String: Any], let context else { return true }
            let collector = Unmanaged<Collector>.fromOpaque(context).takeUnretainedValue()
            guard collector.registrations.count < 65_536,
                  let deviceClass = info[kColorSyncDeviceClass.takeUnretainedValue() as String] as? String,
                  deviceClass == kColorSyncDisplayDeviceClass.takeUnretainedValue() as String,
                  let rawID = info[kColorSyncDeviceID.takeUnretainedValue() as String],
                  CFGetTypeID(rawID as CFTypeRef) == CFUUIDGetTypeID() else { return true }
            let deviceID = CFUUIDCreateString(nil, (rawID as! CFUUID)) as String
            let url = info[kColorSyncDeviceProfileURL.takeUnretainedValue() as String] as? URL
            collector.registrations.append(Registration(deviceClass: deviceClass, deviceID: deviceID,
                                                        profilePath: url?.isFileURL == true ? url?.path : nil))
            return true
        }, context)
        return collector.registrations
    }

    static func liveUnregister(_ registration: Registration) {
        guard let uuid = CFUUIDCreateFromString(nil, registration.deviceID as CFString) else { return }
        _ = ColorSyncUnregisterDevice(registration.deviceClass as CFString, uuid)
    }
}
