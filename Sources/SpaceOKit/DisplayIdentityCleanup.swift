import ApplicationServices
import Foundation

/// Owner-run removal of the ColorSync state that per-attachment display identities left behind
/// (RA-057): `spaceo safety clean-display-identities`.
///
/// Each identity left two layers. Its factory profile is a file; its device registration lives in
/// ColorSync's any-user registry, survives deleting the profile and rebooting, and is what
/// ColorSync re-reads for every display request. `ColorSyncUnregisterDevice` reports success to a
/// non-root caller while removing nothing, so applying requires root, and success is judged only
/// by a fresh enumeration afterwards. Only devices whose *factory* profile names SpaceO's vendor and
/// product are touched; physical displays, Sidecar and other virtual-display tools are left alone,
/// even if someone assigned one of them a SpaceO profile.
public enum DisplayIdentityCleanup {
    public struct Registration: Sendable, Equatable {
        public var deviceClass: String
        public var deviceID: String
        /// Nil when ColorSync lists no readable profile for the device.
        public var profilePath: String?
        /// The profile macOS generated for the device, as opposed to one a person assigned.
        public var isFactory: Bool = false
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
        /// The display inventory changed during cleanup, so no profile was removed.
        public var profileRemovalSkipped: Bool = false
        /// Unreferenced SpaceO profiles that are still present after removal was attempted.
        public var failedProfiles: [String] = []
        public var confirmed: Bool { remainingRegistrations == 0 && !profileRemovalSkipped && failedProfiles.isEmpty }
    }

    public struct DisplayInventory: Sendable, Equatable {
        public var spaceO: Int
        public var other: Int
    }

    public struct Environment {
        public var registrations: () throws -> [Registration]
        public var unregister: (Registration) -> Void
        public var profileDirectory: String
        public var registryPath: String
        public var isRoot: () -> Bool
        public var spaceOProcessRunning: () -> Bool
        public var displays: () throws -> DisplayInventory
        /// Takes the invoking user's display-lifecycle lock, which every display creator needs, and
        /// returns its release. Held from before the first check until the last profile is removed.
        public var acquireExclusion: () throws -> () -> Void
        public var removeProfile: (String) -> Void = { try? FileManager.default.removeItem(atPath: $0) }

        public static let live = Environment(
            registrations: DisplayIdentityCleanup.liveRegistrations,
            unregister: DisplayIdentityCleanup.liveUnregister,
            profileDirectory: DisplayIdentityResidue.profilesDirectory,
            registryPath: DisplayIdentityResidue.registryPath,
            isRoot: { geteuid() == 0 },
            spaceOProcessRunning: DisplayIdentityCleanup.liveSpaceOProcessRunning,
            displays: {
                let online = try Stage.checkedOnlineDisplayIDs()
                let spaceO = online.filter(Stage.isSpaceODisplay).count
                return DisplayInventory(spaceO: spaceO, other: online.count - spaceO)
            },
            acquireExclusion: DisplayIdentityCleanup.liveExclusion)
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case requiresRoot
        case spaceOProcessRunning
        case spaceODisplayOnline
        case noDisplays
        case registryMissing
        case listingTruncated
        case profileInventoryTruncated
        case profileInventoryUnreadable
        case invokingUserUnknown
        case lifecycleJournalUnusable
        case backupFailed(String)

        public var errorDescription: String? {
            switch self {
            case .requiresRoot:
                return "ColorSync ignores unregistration from a normal account; rerun with sudo"
            case .spaceOProcessRunning:
                return "a SpaceO daemon, MCP server or Viewer is running; stop them first (`spaceo daemon stop --operator`, quit the Viewer and MCP clients)"
            case .spaceODisplayOnline:
                return "a SpaceO display is online; stop every SpaceO daemon and Viewer first"
            case .noDisplays:
                return "this process sees no display; run it from a Terminal in the logged-in user's session"
            case .registryMissing:
                return "nothing was removed: ColorSync's device registry is not at \(DisplayIdentityResidue.registryPath), so it cannot be backed up"
            case .listingTruncated:
                return "nothing was removed: ColorSync listed more devices than this command examines"
            case .profileInventoryTruncated:
                return "nothing was removed: \(DisplayIdentityResidue.profilesDirectory) holds more profiles than this command examines"
            case .lifecycleJournalUnusable:
                return "the account's SpaceO display-safety journal cannot be locked; inspect it with `spaceo doctor`"
            case .profileInventoryUnreadable:
                return "nothing was removed: \(DisplayIdentityResidue.profilesDirectory) could not be listed"
            case .invokingUserUnknown:
                return "run this with sudo from the account that uses SpaceO, so it can hold that account's display lock"
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

    public static func plan(_ environment: Environment = .live) throws -> Plan {
        let profiles = try spaceOProfiles(in: environment.profileDirectory)
        let (registrations, unattributed) = spaceODevices(in: try environment.registrations())
        return Plan(registrations: registrations, profilePaths: profiles, unattributedWithoutProfile: unattributed)
    }

    /// ColorSync lists a device once per profile; a device is SpaceO's when its factory profile says so.
    static func spaceODevices(in listing: [Registration]) -> (devices: [Registration], unattributed: Int) {
        var registrations: [Registration] = []
        var spaceO = Set<String>(), profiled = Set<String>(), devices = Set<String>()
        for registration in listing {
            devices.insert(registration.deviceID)
            guard let path = registration.profilePath else { continue }
            profiled.insert(registration.deviceID)
            if registration.isFactory, isSpaceOProfile(path), spaceO.insert(registration.deviceID).inserted {
                registrations.append(registration)
            }
        }
        return (registrations, devices.subtracting(profiled).count)
    }

    /// Every SpaceO profile in the directory, or a refusal; never a partial or substituted list.
    static func spaceOProfiles(in directory: String) throws -> [String] {
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: directory) }
        catch CocoaError.fileReadNoSuchFile { return [] }
        catch { throw Failure.profileInventoryUnreadable }
        let profiles = names.filter { $0.hasSuffix(".icc") }.sorted()
        guard profiles.count <= DisplayIdentityResidue.maximumProfiles else { throw Failure.profileInventoryTruncated }
        return profiles.map { URL(fileURLWithPath: directory).appendingPathComponent($0).path }
            .filter(isSpaceOProfile)
    }

    private static func requireQuiescent(_ environment: Environment) throws {
        guard !environment.spaceOProcessRunning() else { throw Failure.spaceOProcessRunning }
        let displays = try environment.displays()
        guard displays.spaceO == 0 else { throw Failure.spaceODisplayOnline }
        // A process outside the login session can read an empty list successfully.
        guard displays.other > 0 else { throw Failure.noDisplays }
    }

    /// Back up, unregister, verify, then remove the profiles. A registration that is still listed
    /// afterwards keeps every profile it references, and is reported, never assumed removed.
    public static func apply(_ environment: Environment = .live, backupRoot: String,
                             now: Date = Date()) throws -> Outcome {
        guard environment.isRoot() else { throw Failure.requiresRoot }
        let release = try environment.acquireExclusion()
        defer { release() }
        try requireQuiescent(environment)
        let plan = try Self.plan(environment)
        let manager = FileManager.default
        guard manager.fileExists(atPath: environment.registryPath) else { throw Failure.registryMissing }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: now)
        let backup = URL(fileURLWithPath: backupRoot).appendingPathComponent("colorsync-\(stamp)")
        do {
            try manager.createDirectory(at: backup.appendingPathComponent("Profiles"),
                                        withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try manager.copyItem(atPath: environment.registryPath,
                                 toPath: backup.appendingPathComponent("com.apple.colorsync.devices").path)
            for path in plan.profilePaths {
                let name = URL(fileURLWithPath: path).lastPathComponent
                try manager.copyItem(atPath: path, toPath: backup.appendingPathComponent("Profiles/\(name)").path)
            }
        } catch {
            throw Failure.backupFailed(error.localizedDescription)
        }

        for registration in plan.registrations { environment.unregister(registration) }
        let after = try environment.registrations()
        let remaining = spaceODevices(in: after).devices.count
        var outcome = Outcome(plan: plan, backup: backup.path,
                              unregistered: plan.registrations.count - remaining,
                              remainingRegistrations: remaining, movedProfiles: 0)
        // The lifecycle lock keeps SpaceO creators out; anything else attaching a SpaceO display
        // (an old binary, a direct private-API user) would own one of these profiles.
        do { try requireQuiescent(environment) } catch {
            outcome.profileRemovalSkipped = true
            return outcome
        }
        // Never remove a profile that any registration still references; ColorSync would recreate it.
        let referenced = Set(after.compactMap(\.profilePath))
        for path in plan.profilePaths where !referenced.contains(path) {
            environment.removeProfile(path)
            if manager.fileExists(atPath: path) { outcome.failedProfiles.append(path) }
            else { outcome.movedProfiles += 1 }
        }
        return outcome
    }

    // MARK: - ColorSync

    private final class Collector {
        static let limit = 65_536
        var registrations: [Registration] = []
        var truncated = false
    }

    static func liveRegistrations() throws -> [Registration] {
        let collector = Collector()
        let context = Unmanaged.passUnretained(collector).toOpaque()
        ColorSyncIterateDeviceProfiles({ info, context in
            guard let info = info as? [String: Any], let context else { return true }
            let collector = Unmanaged<Collector>.fromOpaque(context).takeUnretainedValue()
            guard collector.registrations.count < Collector.limit else {
                collector.truncated = true
                return false
            }
            guard let deviceClass = info[kColorSyncDeviceClass.takeUnretainedValue() as String] as? String,
                  deviceClass == kColorSyncDisplayDeviceClass.takeUnretainedValue() as String,
                  let rawID = info[kColorSyncDeviceID.takeUnretainedValue() as String],
                  CFGetTypeID(rawID as CFTypeRef) == CFUUIDGetTypeID() else { return true }
            let deviceID = CFUUIDCreateString(nil, (rawID as! CFUUID)) as String
            let url = info[kColorSyncDeviceProfileURL.takeUnretainedValue() as String] as? URL
            let factory = info[kColorSyncDeviceProfileIsFactory.takeUnretainedValue() as String] as? Bool ?? false
            collector.registrations.append(Registration(deviceClass: deviceClass, deviceID: deviceID,
                                                        profilePath: url?.isFileURL == true ? url?.path : nil,
                                                        isFactory: factory))
            return true
        }, context)
        guard !collector.truncated else { throw Failure.listingTruncated }
        return collector.registrations
    }

    /// Any other `spaceo` process (daemon, MCP server, CLI) or the Viewer could attach a display
    /// during the tens of seconds cleanup takes. An unreadable process list counts as running.
    static func liveSpaceOProcessRunning() -> Bool {
        let me = getpid()
        var pids = [pid_t](repeating: 0, count: 16_384)
        let count = pids.withUnsafeMutableBytes {
            proc_listallpids($0.baseAddress, Int32($0.count))
        }
        guard count > 0, Int(count) < pids.count else { return true }
        for pid in pids.prefix(Int(count)) where pid > 0 && pid != me {
            var name = [CChar](repeating: 0, count: 256)
            guard proc_name(pid, &name, UInt32(name.count)) > 0 else { continue }
            let process = String(cString: name)
            if process == "spaceo" || process == "SpaceO Viewer" { return true }
        }
        return false
    }

    /// The invoking account's lifecycle journal lock (`sudo` sets `SUDO_UID`). Every SpaceO display
    /// creator takes it, so holding it keeps the daemon, Viewer and MCP servers from attaching a
    /// display mid-cleanup. A journal created here belongs to that account, never to root; an empty
    /// journal is the state SpaceO starts from.
    static func liveExclusion() throws -> () -> Void {
        guard let text = ProcessInfo.processInfo.environment["SUDO_UID"], let uid = uid_t(text), uid != 0,
              let entry = getpwuid(uid), let home = entry.pointee.pw_dir else {
            throw Failure.invokingUserUnknown
        }
        let gid = entry.pointee.pw_gid
        let directory = String(cString: home) + "/Library/Application Support/SpaceO"
        var directoryInfo = stat()
        guard lstat(directory, &directoryInfo) == 0, directoryInfo.st_mode & S_IFMT == S_IFDIR,
              directoryInfo.st_uid == uid else { throw Failure.invokingUserUnknown }
        let path = directory + "/display-safety.json"
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw Failure.lifecycleJournalUnusable }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            close(fd)
            throw Failure.lifecycleJournalUnusable
        }
        // Only a journal this call just created (root-owned and empty) changes owner.
        if info.st_uid != uid {
            guard info.st_uid == 0, info.st_size == 0, fchown(fd, uid, gid) == 0 else {
                close(fd)
                throw Failure.lifecycleJournalUnusable
            }
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw Failure.spaceOProcessRunning
        }
        return { close(fd) }
    }

    static func liveUnregister(_ registration: Registration) {
        guard let uuid = CFUUIDCreateFromString(nil, registration.deviceID as CFString) else { return }
        _ = ColorSyncUnregisterDevice(registration.deviceClass as CFString, uuid)
    }
}
