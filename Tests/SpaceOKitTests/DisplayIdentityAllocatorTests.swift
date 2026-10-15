import Foundation
import XCTest
@testable import SpaceOKit

/// RA-057: every display identity leaves permanent ColorSync and WindowServer state, so identities
/// must come from a bounded set that survives process restarts. These tests use a temporary
/// generations file and plain objects in place of displays; nothing touches the display server.
final class DisplayIdentityAllocatorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spaceo-identities-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var path: String { directory.appendingPathComponent("display-identities.json").path }

    func testSerialIsAPureNonzeroFunctionOfGeometrySlotAndGeneration() {
        let key = DisplayIdentityAllocator.key(width: 1_920, height: 1_080, hiDPI: true)
        XCTAssertEqual(key, "1920x1080@2")
        let serial = DisplayIdentityAllocator.serial(key: key, slot: 0, generation: 0)
        XCTAssertNotEqual(serial, 0)
        XCTAssertEqual(serial, DisplayIdentityAllocator.serial(key: key, slot: 0, generation: 0),
                       "a restarted daemon must derive the same identity")
        XCTAssertNotEqual(serial, DisplayIdentityAllocator.serial(key: key, slot: 1, generation: 0))
        XCTAssertNotEqual(serial, DisplayIdentityAllocator.serial(key: key, slot: 0, generation: 1))
        XCTAssertNotEqual(serial, DisplayIdentityAllocator.serial(key: "1920x1080@1", slot: 0, generation: 0))
    }

    func testEverySlotOfACommonGeometryHasADistinctSerial() {
        for key in ["1920x1080@2", "1920x1080@1", "2560x1440@2", "1280x800@2"] {
            let serials = (0..<DisplayIdentityAllocator.slotCount).map {
                DisplayIdentityAllocator.serial(key: key, slot: $0, generation: 0)
            }
            XCTAssertEqual(Set(serials).count, serials.count, key)
        }
    }

    func testSequentialLifecyclesReuseOneIdentity() throws {
        let allocator = DisplayIdentityAllocator(path: path)
        var serials = Set<UInt32>()
        for _ in 0..<100 {
            let identity = try XCTUnwrap(allocator.claim(width: 1_920, height: 1_080, hiDPI: true,
                                                         onlineSerials: []))
            autoreleasepool {
                let display = NSObject()
                allocator.bind(identity, to: display)
            }
            serials.insert(identity.serial)
        }
        XCTAssertEqual(serials.count, 1, "a display that is gone frees its identity for the next one")
    }

    func testLiveDisplaysAndPendingClaimsHoldTheirSlots() throws {
        let allocator = DisplayIdentityAllocator(path: path)
        let first = try XCTUnwrap(allocator.claim(width: 1_920, height: 1_080, hiDPI: true, onlineSerials: []))
        let pending = try XCTUnwrap(allocator.claim(width: 1_920, height: 1_080, hiDPI: true, onlineSerials: []))
        XCTAssertEqual([first.slot, pending.slot], [0, 1], "an unbound claim is still busy")

        let display = NSObject()
        allocator.bind(first, to: display)
        let third = try XCTUnwrap(allocator.claim(width: 1_920, height: 1_080, hiDPI: true, onlineSerials: []))
        XCTAssertEqual(third.slot, 2)

        allocator.abandon(pending)
        allocator.abandon(first)
        XCTAssertEqual(allocator.claim(width: 1_920, height: 1_080, hiDPI: true, onlineSerials: [])?.slot, 1,
                       "abandon frees an unbound claim but never a bound display")
        withExtendedLifetime(display) {}
    }

    func testIdentitiesOnlineInAnyProcessAreSkipped() throws {
        let allocator = DisplayIdentityAllocator(path: path)
        let key = DisplayIdentityAllocator.key(width: 1_920, height: 1_080, hiDPI: true)
        let online: Set<UInt32> = [
            DisplayIdentityAllocator.serial(key: key, slot: 0, generation: 0),
            DisplayIdentityAllocator.serial(key: key, slot: 1, generation: 0),
        ]
        let identity = try XCTUnwrap(allocator.claim(width: 1_920, height: 1_080, hiDPI: true,
                                                     onlineSerials: online))
        XCTAssertEqual(identity.slot, 2)
    }

    func testGeometriesHaveIndependentSlots() throws {
        let allocator = DisplayIdentityAllocator(path: path)
        let small = try XCTUnwrap(allocator.claim(width: 1_280, height: 800, hiDPI: true, onlineSerials: []))
        let large = try XCTUnwrap(allocator.claim(width: 2_560, height: 1_440, hiDPI: true, onlineSerials: []))
        XCTAssertEqual([small.slot, large.slot], [0, 0])
        XCTAssertNotEqual(small.serial, large.serial)
    }

    func testAllSlotsBusyRefusesInsteadOfMintingAnIdentity() {
        let allocator = DisplayIdentityAllocator(path: path)
        for _ in 0..<DisplayIdentityAllocator.slotCount {
            XCTAssertNotNil(allocator.claim(width: 1_920, height: 1_080, hiDPI: true, onlineSerials: []))
        }
        XCTAssertNil(allocator.claim(width: 1_920, height: 1_080, hiDPI: true, onlineSerials: []))
    }

    func testRotationRetiresAPoisonedIdentityAcrossRestarts() throws {
        let allocator = DisplayIdentityAllocator(path: path)
        let poisoned = try XCTUnwrap(allocator.claim(width: 1_920, height: 1_080, hiDPI: true, onlineSerials: []))
        XCTAssertTrue(allocator.rotate(poisoned))
        XCTAssertTrue(allocator.rotate(poisoned), "a stale rotation is a no-op, not a second bump")
        allocator.abandon(poisoned)

        let restarted = DisplayIdentityAllocator(path: path)
        XCTAssertEqual(restarted.generation(key: poisoned.key, slot: 0), 1)
        let next = try XCTUnwrap(restarted.claim(width: 1_920, height: 1_080, hiDPI: true, onlineSerials: []))
        XCTAssertEqual(next.slot, 0)
        XCTAssertEqual(next.generation, 1)
        XCTAssertNotEqual(next.serial, poisoned.serial)

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testMalformedOrForeignGenerationFilesFallBackToGenerationZero() throws {
        let key = DisplayIdentityAllocator.key(width: 1_920, height: 1_080, hiDPI: true)
        for contents in ["not json", #"{"version":2,"generations":{"1920x1080@2/0":4}}"#,
                         #"{"version":1,"generations":{"1920x1080@2/0":-3}}"#] {
            try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
            let allocator = DisplayIdentityAllocator(path: path)
            XCTAssertEqual(allocator.generation(key: key, slot: 0), 0, contents)
        }
        try Data(#"{"version":1,"generations":{"1920x1080@2/0":4}}"#.utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(DisplayIdentityAllocator(path: path).generation(key: key, slot: 0), 4)
    }

    func testPersistedGenerationsAreBounded() throws {
        let allocator = DisplayIdentityAllocator(path: path)
        var rotated = 0
        for width in 0..<(DisplayIdentityAllocator.maximumPersistedKeys + 4) {
            let identity = try XCTUnwrap(allocator.claim(width: UInt32(100 + width), height: 100, hiDPI: false,
                                                         onlineSerials: []))
            if allocator.rotate(identity) { rotated += 1 }
        }
        XCTAssertEqual(rotated, DisplayIdentityAllocator.maximumPersistedKeys)
    }
}

/// Doctor counts SpaceO's leftover ColorSync profiles by their `mmod` tag, not by file name.
final class DisplayIdentityResidueTests: XCTestCase {
    private func profile(vendor: UInt32, product: UInt32, tagged: Bool = true) -> Data {
        func word(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.bigEndian, Array.init) }
        var bytes = [UInt8](repeating: 0, count: 128)
        bytes += word(tagged ? 2 : 1)
        bytes += word(0x6465_7363) + word(200) + word(12)       // 'desc', ignored
        if tagged { bytes += word(0x6D6D_6F64) + word(156) + word(40) }  // 'mmod'
        bytes += [UInt8](repeating: 0, count: 156 - bytes.count)
        bytes += word(0x6D6D_6F64) + word(0) + word(vendor) + word(product) + word(42)
        bytes += [UInt8](repeating: 0, count: 64)
        return Data(bytes)
    }

    func testParsesTheMakeAndModelTag() throws {
        let model = try XCTUnwrap(DisplayIdentityResidue.displayModel(profile: profile(vendor: 0x1AF2, product: 1)))
        XCTAssertEqual(model.vendor, 0x1AF2)
        XCTAssertEqual(model.product, 1)
        XCTAssertNil(DisplayIdentityResidue.displayModel(profile: profile(vendor: 0x1AF2, product: 1, tagged: false)))
        XCTAssertNil(DisplayIdentityResidue.displayModel(profile: Data([0, 1, 2])))
        var truncated = profile(vendor: 0x1AF2, product: 1)
        truncated.removeLast(70)
        XCTAssertNil(DisplayIdentityResidue.displayModel(profile: truncated))
    }

    func testScanCountsOnlySpaceOProfilesAndFlagsAccumulation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spaceo-residue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<70 {
            try profile(vendor: 0x1AF2, product: 1).write(to: directory.appendingPathComponent("test-\(index).icc"))
        }
        try profile(vendor: 0x610, product: 0xA05E).write(to: directory.appendingPathComponent("Color LCD.icc"))
        try profile(vendor: 0x1AF2, product: 2).write(to: directory.appendingPathComponent("SpaceO display 1.icc"))
        try Data("x".utf8).write(to: directory.appendingPathComponent("notes.txt"))
        let registry = directory.appendingPathComponent("registry")
        try Data(count: 4_096).write(to: registry)

        let residue = try XCTUnwrap(DisplayIdentityResidue.scan(directory: directory.path, registry: registry.path))
        XCTAssertEqual(residue.spaceOProfiles, 70)
        XCTAssertEqual(residue.totalProfiles, 72)
        XCTAssertEqual(residue.registryBytes, 4_096)
        XCTAssertTrue(residue.needsCleanup)
        XCTAssertTrue(residue.summary.contains("docs/DISPLAY_SAFETY.md#display-identity-residue"))
        XCTAssertNil(DisplayIdentityResidue.scan(directory: directory.appendingPathComponent("missing").path))
    }
}

/// The owner-run cleanup touches only SpaceO's registrations, backs up first, and judges success
/// by a fresh listing, never by ColorSync's return value. ColorSync itself is replaced here.
final class DisplayIdentityCleanupTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spaceo-cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Displays"),
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func writeProfile(_ name: String, vendor: UInt32, product: UInt32) throws -> String {
        func word(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.bigEndian, Array.init) }
        var bytes = [UInt8](repeating: 0, count: 128) + word(1) + word(0x6D6D_6F64) + word(144) + word(40)
        bytes += word(0x6D6D_6F64) + word(0) + word(vendor) + word(product) + [UInt8](repeating: 0, count: 40)
        let url = directory.appendingPathComponent("Displays/\(name).icc")
        try Data(bytes).write(to: url)
        return url.path
    }

    private final class FakeColorSync {
        var registrations: [DisplayIdentityCleanup.Registration] = []
        var ignoresUnregister = false
        var unregistered: [String] = []
        var displays = [DisplayIdentityCleanup.DisplayInventory(spaceO: 0, other: 1)]
        var displayReads = 0
        var listingFails = false
    }

    private func environment(_ colorSync: FakeColorSync, root: Bool = true, processRunning: Bool = false,
                             registry: Bool = true) -> DisplayIdentityCleanup.Environment {
        let registryURL = directory.appendingPathComponent("registry")
        if registry { try? Data(count: 512).write(to: registryURL) }
        return DisplayIdentityCleanup.Environment(
            registrations: {
                if colorSync.listingFails { throw DisplayIdentityCleanup.Failure.listingTruncated }
                return colorSync.registrations
            },
            unregister: { registration in
                colorSync.unregistered.append(registration.deviceID)
                if !colorSync.ignoresUnregister {
                    colorSync.registrations.removeAll { $0.deviceID == registration.deviceID }
                }
            },
            profileDirectory: directory.appendingPathComponent("Displays").path,
            registryPath: registryURL.path,
            isRoot: { root },
            spaceOProcessRunning: { processRunning },
            displays: {
                defer { colorSync.displayReads += 1 }
                return colorSync.displays[min(colorSync.displayReads, colorSync.displays.count - 1)]
            })
    }

    private func fixture() throws -> FakeColorSync {
        let colorSync = FakeColorSync()
        let spaceO = try writeProfile("SpaceO display 1-A", vendor: 0x1AF2, product: 1)
        let test = try writeProfile("test-multi-1-B", vendor: 0x1AF2, product: 1)
        let builtIn = try writeProfile("Color LCD-C", vendor: 0x610, product: 0xA05E)
        let otherTool = try writeProfile("Other-D", vendor: 0x1AF2, product: 2)
        _ = try writeProfile("SpaceO display 2-E", vendor: 0x1AF2, product: 1)  // no registration
        colorSync.registrations = [
            .init(deviceClass: "mntr", deviceID: "A", profilePath: spaceO),
            .init(deviceClass: "mntr", deviceID: "A", profilePath: builtIn),  // custom profile on a SpaceO device
            .init(deviceClass: "mntr", deviceID: "B", profilePath: test),
            .init(deviceClass: "mntr", deviceID: "C", profilePath: builtIn),
            .init(deviceClass: "mntr", deviceID: "D", profilePath: otherTool),
            .init(deviceClass: "mntr", deviceID: "F", profilePath: nil),
        ]
        return colorSync
    }

    func testPlanSelectsOnlySpaceORegistrationsAndProfiles() throws {
        let colorSync = try fixture()
        let plan = try DisplayIdentityCleanup.plan(environment(colorSync))
        XCTAssertEqual(plan.registrations.map(\.deviceID), ["A", "B"])
        XCTAssertEqual(plan.profilePaths.map { URL(fileURLWithPath: $0).lastPathComponent },
                       ["SpaceO display 1-A.icc", "SpaceO display 2-E.icc", "test-multi-1-B.icc"])
        XCTAssertEqual(plan.unattributedWithoutProfile, 1, "a registration without a profile is left alone")
    }

    func testApplyRefusesUnlessRootQuiescentAndBackedUp() throws {
        let backupRoot = directory.appendingPathComponent("b").path
        func refusal(_ environment: DisplayIdentityCleanup.Environment) -> DisplayIdentityCleanup.Failure? {
            do { _ = try DisplayIdentityCleanup.apply(environment, backupRoot: backupRoot); return nil }
            catch { return error as? DisplayIdentityCleanup.Failure }
        }
        let colorSync = try fixture()
        XCTAssertEqual(refusal(environment(colorSync, root: false)), .requiresRoot)
        XCTAssertEqual(refusal(environment(colorSync, processRunning: true)), .spaceOProcessRunning)
        colorSync.displays = [.init(spaceO: 1, other: 1)]
        XCTAssertEqual(refusal(environment(colorSync)), .spaceODisplayOnline)
        colorSync.displays = [.init(spaceO: 0, other: 0)]
        XCTAssertEqual(refusal(environment(colorSync)), .noDisplays, "an empty inventory is not proof of quiet")
        colorSync.displays = [.init(spaceO: 0, other: 1)]
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("registry"))
        XCTAssertEqual(refusal(environment(colorSync, registry: false)), .registryMissing)
        colorSync.listingFails = true
        XCTAssertEqual(refusal(environment(colorSync)), .listingTruncated)
        XCTAssertTrue(colorSync.unregistered.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupRoot))
    }

    func testADisplayAppearingDuringCleanupKeepsEveryProfile() throws {
        let colorSync = try fixture()
        colorSync.displays = [.init(spaceO: 0, other: 1), .init(spaceO: 1, other: 1)]
        let outcome = try DisplayIdentityCleanup.apply(environment(colorSync),
                                                       backupRoot: directory.appendingPathComponent("backup").path)
        XCTAssertTrue(outcome.profileRemovalSkipped)
        XCTAssertFalse(outcome.confirmed)
        XCTAssertEqual(outcome.movedProfiles, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: directory.appendingPathComponent("Displays").path).count, 5)
    }

    func testEveryProfileOfASurvivingRegistrationIsKept() throws {
        let colorSync = try fixture()
        let second = try writeProfile("SpaceO display 1-A2", vendor: 0x1AF2, product: 1)
        colorSync.registrations.append(.init(deviceClass: "mntr", deviceID: "A", profilePath: second))
        colorSync.ignoresUnregister = true
        let outcome = try DisplayIdentityCleanup.apply(environment(colorSync),
                                                       backupRoot: directory.appendingPathComponent("backup").path)
        XCTAssertEqual(outcome.remainingRegistrations, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second), "a device's second profile is still referenced")
        XCTAssertEqual(outcome.movedProfiles, 1)
    }

    func testApplyBacksUpUnregistersAndRemovesSpaceOProfiles() throws {
        let colorSync = try fixture()
        let outcome = try DisplayIdentityCleanup.apply(environment(colorSync),
                                                       backupRoot: directory.appendingPathComponent("backup").path)
        XCTAssertTrue(outcome.confirmed)
        XCTAssertEqual(colorSync.unregistered, ["A", "B"])
        XCTAssertEqual(outcome.unregistered, 2)
        XCTAssertEqual(outcome.movedProfiles, 3)
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Displays").path)
        XCTAssertEqual(Set(left), ["Color LCD-C.icc", "Other-D.icc"])
        let backedUp = try FileManager.default.contentsOfDirectory(atPath: outcome.backup + "/Profiles")
        XCTAssertEqual(backedUp.count, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outcome.backup + "/com.apple.colorsync.devices"))
    }

    func testIgnoredUnregistrationIsReportedAndKeepsItsProfiles() throws {
        let colorSync = try fixture()
        colorSync.ignoresUnregister = true
        let outcome = try DisplayIdentityCleanup.apply(environment(colorSync),
                                                       backupRoot: directory.appendingPathComponent("backup").path)
        XCTAssertFalse(outcome.confirmed, "ColorSync's success is never trusted without a fresh listing")
        XCTAssertEqual(outcome.remainingRegistrations, 2)
        XCTAssertEqual(outcome.unregistered, 0)
        XCTAssertEqual(outcome.movedProfiles, 1, "only the unregistered orphan profile is removed")
    }
}
