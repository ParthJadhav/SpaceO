import Foundation

/// What earlier SpaceO versions left in ColorSync (RA-057), for `spaceo doctor`.
///
/// Before identities were bounded every attachment registered a new ColorSync device and wrote a
/// factory profile that macOS never removes. Only an administrator can delete them, so doctor
/// reports the count and the registry size and points at the documented owner-run cleanup.
public struct DisplayIdentityResidue: Sendable, Equatable, Codable {
    /// Display profiles whose `mmod` tag names SpaceO's vendor and product.
    public var spaceOProfiles: Int
    public var totalProfiles: Int
    /// True when the directory held more entries than doctor examines; counts are then lower bounds.
    public var truncated: Bool
    public var registryBytes: Int?

    public static let profilesDirectory = "/Library/ColorSync/Profiles/Displays"
    public static let registryPath = "/Library/Caches/ColorSync/com.apple.colorsync.devices"
    static let maximumProfiles = 4_096
    static let maximumProfileBytes = 1_048_576
    /// Bounded identities leave a handful; hundreds only come from per-attachment identities.
    public static let cleanupThreshold = 64

    /// A truncated scan is incomplete, so it never reports the residue as bounded.
    public var needsCleanup: Bool { truncated || spaceOProfiles > Self.cleanupThreshold }

    enum ListingError: Error { case missing, unreadable }

    /// At most `maximum` `.icc` names, sorted, and whether the directory holds more. Reads entries
    /// one at a time and stops at the bound, so an enormous directory cannot stall or exhaust memory.
    static func profileNames(in directory: String, maximum: Int = maximumProfiles,
                             maximumEntries: Int = 4 * maximumProfiles) throws -> (names: [String], truncated: Bool) {
        guard let handle = opendir(directory) else {
            throw errno == ENOENT ? ListingError.missing : ListingError.unreadable
        }
        defer { closedir(handle) }
        var names: [String] = [], entries = 0
        while true {
            errno = 0
            guard let entry = readdir(handle) else {
                if errno != 0 { throw ListingError.unreadable }
                return (names.sorted(), false)
            }
            var raw = entry.pointee.d_name
            let name = withUnsafeBytes(of: &raw) { String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self) }
            guard name != ".", name != ".." else { continue }
            entries += 1
            if name.hasSuffix(".icc") { names.append(name) }
            if names.count > maximum || entries > maximumEntries {
                return (Array(names.sorted().prefix(maximum)), true)
            }
        }
    }

    public static func scan(directory: String = profilesDirectory,
                            registry: String = registryPath) -> DisplayIdentityResidue? {
        guard let listing = try? profileNames(in: directory) else { return nil }
        let profiles = listing.names
        var spaceO = 0
        for name in profiles {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
            guard let data = try? BoundedRegularFile.read(url, maximumBytes: maximumProfileBytes),
                  let model = displayModel(profile: data) else { continue }
            if model.vendor == 0x1AF2, model.product == 0x0001 { spaceO += 1 }
        }
        let registryBytes = (try? FileManager.default.attributesOfItem(atPath: registry))?[.size] as? Int
        return DisplayIdentityResidue(spaceOProfiles: spaceO, totalProfiles: profiles.count,
                                      truncated: listing.truncated, registryBytes: registryBytes)
    }

    /// The vendor and product in an ICC profile's Apple `mmod` tag, or nil when absent or malformed.
    static func displayModel(profile data: Data) -> (vendor: UInt32, product: UInt32)? {
        let bytes = [UInt8](data)
        func word(_ offset: Int) -> UInt32? {
            guard offset >= 0, offset + 4 <= bytes.count else { return nil }
            return bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }
        guard let count = word(128), count <= 1_024 else { return nil }
        for index in 0..<Int(count) {
            let entry = 132 + 12 * index
            guard let signature = word(entry), let offset = word(entry + 4), let size = word(entry + 8) else {
                return nil
            }
            guard signature == 0x6D6D_6F64 else { continue } // 'mmod'
            guard size >= 16, Int(offset) + 16 <= bytes.count,
                  let vendor = word(Int(offset) + 8), let product = word(Int(offset) + 12) else { return nil }
            return (vendor, product)
        }
        return nil
    }

    public var summary: String {
        let registry = registryBytes.map { " ColorSync registry \($0 / 1_024) KB;" } ?? ""
        let counted = truncated
            ? "at least \(spaceOProfiles) SpaceO display profiles among more than \(Self.maximumProfiles) (scan stopped at its bound);"
            : "\(spaceOProfiles) of \(totalProfiles) display profiles are SpaceO's;"
        if spaceOProfiles > Self.cleanupThreshold {
            return "\(counted)\(registry) left by earlier versions and slow every display change — see docs/DISPLAY_SAFETY.md#display-identity-residue"
        }
        return truncated
            ? "\(counted)\(registry) scan incomplete — see docs/DISPLAY_SAFETY.md#display-identity-residue"
            : "\(counted)\(registry) bounded"
    }
}
