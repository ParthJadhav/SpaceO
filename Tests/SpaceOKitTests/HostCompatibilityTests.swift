import SpaceOPrivate
import XCTest
@testable import SpaceOKit

final class HostCompatibilityTests: XCTestCase {

    private let capability = SPOCapability.focusWithoutRaise

    func testExactTupleMatchWithRecordedEvidenceQualifiesOnlyThatCapability() {
        let observed = host()
        let recorded = host(evidence: "evidence/disposable-login/14.6.1-23G93-arm64.md")
        let registry = [
            SPOHostQualification(capability: capability, host: recorded),
        ]

        XCTAssertTrue(
            SPOHostIsQualifiedForCapability(capability, observed, registry)
        )
        XCTAssertFalse(
            SPOHostIsQualifiedForCapability(.virtualDisplay, observed, registry),
            "qualification is capability-specific even on the same tuple"
        )
        XCTAssertTrue(
            SPOCapabilityAllowedForHost(capability, observed, registry, true)
        )
    }

    func testBuildArchitectureAndOSVersionMismatchesFailClosed() {
        let recorded = host(evidence: "evidence/disposable-login/14.6.1-23G93-arm64.md")
        let registry = [
            SPOHostQualification(capability: capability, host: recorded),
        ]

        XCTAssertFalse(
            SPOHostIsQualifiedForCapability(
                capability,
                host(build: "23G94"),
                registry
            )
        )
        XCTAssertFalse(
            SPOHostIsQualifiedForCapability(
                capability,
                host(architecture: "x86_64"),
                registry
            )
        )
        XCTAssertFalse(
            SPOHostIsQualifiedForCapability(
                capability,
                host(patch: 2),
                registry
            )
        )
    }

    func testSymbolPresenceCannotBypassMissingOrMismatchedQualification() {
        let observed = host()
        let wrongHost = host(
            build: "23G94",
            evidence: "evidence/disposable-login/14.6.1-23G94-arm64.md"
        )
        let wrongRegistry = [
            SPOHostQualification(capability: capability, host: wrongHost),
        ]

        XCTAssertFalse(
            SPOCapabilityAllowedForHost(capability, observed, [], true),
            "a present symbol is not host compatibility evidence"
        )
        XCTAssertFalse(
            SPOCapabilityAllowedForHost(capability, observed, wrongRegistry, true),
            "a present symbol on a near-match host must still fail closed"
        )
    }

    func testEvidenceReferenceIsRequiredAndMissingBehaviorStillFails() {
        let observed = host()
        let undocumented = host(evidence: " \n ")
        let undocumentedRegistry = [
            SPOHostQualification(capability: capability, host: undocumented),
        ]
        XCTAssertFalse(
            SPOHostIsQualifiedForCapability(
                capability,
                observed,
                undocumentedRegistry
            )
        )

        let recorded = host(evidence: "evidence/disposable-login/14.6.1-23G93-arm64.md")
        let registry = [
            SPOHostQualification(capability: capability, host: recorded),
        ]
        XCTAssertFalse(
            SPOCapabilityAllowedForHost(capability, observed, registry, false),
            "qualification does not excuse a missing runtime symbol/class"
        )
    }

    func testBuiltInRegistryQualifiesOnlyRecordedSurfacesOnTheExactDevelopmentHost() {
        let registry = SPOQualifiedHostRegistry()
        XCTAssertEqual(registry.count, 4)

        let current = SPOCurrentHostTuple()
        let isRecordedHost =
            current.operatingSystemMajor == 27
            && current.operatingSystemMinor == 0
            && current.operatingSystemPatch == 0
            && current.darwinBuild == "26A5368g"
            && current.architecture == "arm64"

        for capability: SPOCapability in [
            .virtualDisplay, .spaceQuery, .perPIDEvents, .axWindowID,
        ] {
            XCTAssertEqual(
                SPOHostIsQualifiedForCapability(capability, current, registry),
                isRecordedHost
            )
        }
        XCTAssertFalse(
            SPOHostIsQualifiedForCapability(.focusWithoutRaise, current, registry),
            "the unqualified focus-record layout must stay disabled"
        )
    }

    func testCurrentHostCapabilitiesMatchTheExactQualificationRegistry() {
        let capabilities = Capabilities()
        let current = SPOCurrentHostTuple()
        let isRecordedHost =
            current.operatingSystemMajor == 27
            && current.operatingSystemMinor == 0
            && current.operatingSystemPatch == 0
            && current.darwinBuild == "26A5368g"
            && current.architecture == "arm64"

        XCTAssertEqual(capabilities.privateAPIHost.registryEntryCount, 4)
        XCTAssertEqual(
            Set(capabilities.privateAPIHost.qualifiedCapabilities),
            isRecordedHost
                ? Set([
                    "virtual-display", "space-query", "per-pid-events", "ax-window-id",
                ])
                : []
        )

        let focus = capabilities.items.first { $0.name == "focus-without-raise" }
        XCTAssertEqual(focus?.available, false)
        XCTAssertTrue(
            focus?.unavailableReason?.contains("no evidence-backed qualified tuples") == true
        )
        XCTAssertEqual(
            capabilities.canDrive,
            isRecordedHost
                && capabilities.items.first { $0.name == "accessibility" }?.available == true
        )
    }

    private func host(
        major: Int = 14,
        minor: Int = 6,
        patch: Int = 1,
        build: String = "23G93",
        architecture: String = "arm64",
        evidence: String? = nil
    ) -> SPOHostTuple {
        SPOHostTuple(
            operatingSystemMajor: major,
            minor: minor,
            patch: patch,
            darwinBuild: build,
            architecture: architecture,
            evidenceReference: evidence
        )
    }
}
