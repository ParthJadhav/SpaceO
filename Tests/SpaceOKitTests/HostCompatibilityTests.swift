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

    func testBuiltInRegistryIsEmptyAndCurrentHostReportsUnsupportedReason() {
        XCTAssertTrue(
            SPOQualifiedHostRegistry().isEmpty,
            "no host may be enabled before disposable-login evidence is recorded"
        )
        let reason = SPOCapabilityUnavailableReason(.virtualDisplay)
        XCTAssertTrue(reason?.contains("no evidence-backed qualified tuples") == true)
        XCTAssertTrue(reason?.contains("Symbol/class presence is insufficient") == true)
        XCTAssertTrue(reason?.contains(SPOHostTupleDescription(SPOCurrentHostTuple())) == true)
    }

    func testCapabilitiesAndStageCreationSurfaceTheUnsupportedHostReason() {
        let capabilities = Capabilities()
        XCTAssertFalse(capabilities.canDrive)
        XCTAssertEqual(capabilities.privateAPIHost.registryEntryCount, 0)
        XCTAssertTrue(capabilities.privateAPIHost.qualifiedCapabilities.isEmpty)

        let privateItems = capabilities.items.filter {
            [
                "virtual-display",
                "focus-without-raise",
                "space-query",
                "per-pid-events",
                "ax-window-id",
            ].contains($0.name)
        }
        XCTAssertEqual(privateItems.count, 5)
        XCTAssertTrue(privateItems.allSatisfy { !$0.available })
        XCTAssertTrue(privateItems.allSatisfy {
            $0.unavailableReason?.contains("no evidence-backed qualified tuples") == true
        })
        XCTAssertTrue(capabilities.report.contains("qualified surfaces: none"))

        XCTAssertThrowsError(try Stage(name: "must-not-be-created")) { error in
            XCTAssertTrue(
                error.localizedDescription.contains(
                    "no evidence-backed qualified tuples"
                )
            )
        }
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
