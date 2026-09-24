// Standalone harness for Sources/SpaceOKit/AXSnapshotDiff.swift. Compile this file together
// with that source file as the baseline; for the lookup candidate, change only
// baseByKey.removeValue(forKey: key) to baseByKey[key] in a temporary source copy.
// Example from the repository root:
//   swiftc -O Sources/SpaceOKit/AXSnapshotDiff.swift scripts/benchmark-snapshot-lookup.swift -o /tmp/spaceo-snapshot-baseline
//   python3 -c 'from pathlib import Path; s=Path("Sources/SpaceOKit/AXSnapshotDiff.swift").read_text(); a="baseByKey.removeValue(forKey: key)"; assert s.count(a)==1; Path("/tmp/spaceo-snapshot-lookup.swift").write_text(s.replace(a,"baseByKey[key]"))'
//   swiftc -O /tmp/spaceo-snapshot-lookup.swift scripts/benchmark-snapshot-lookup.swift -o /tmp/spaceo-snapshot-lookup
// Run each executable in its own process; the CPU time samples and peak RSS are process-local.
// Stub AXNode/ScreenDiff types keep AX providers and package targets out of the measurement.

import Foundation
import CoreGraphics
import Darwin

public struct AXNode: Sendable {
    public let index: Int?
    public let role: String
    public let label: String
    public let frame: CGRect?
    public let actions: [String]
    public let depth: Int
    public let enabled: Bool

    public func renderedLine(label: String? = nil, indented: Bool) -> String {
        let value = label ?? self.label
        let prefix = indented ? String(repeating: "  ", count: depth) : ""
        return prefix + role + " — " + value
    }
}

public struct ScreenDiff {
    public let baseSnapshotID: String
    public let added: [String]
    public let removed: [String]
    public let changed: [String]
    public let unchangedCount: Int
    public let baseMissing: Bool
}

@main
enum BenchmarkSnapshotLookup {
    static let nodeCount = 4_000
    static let repeats = 300
    static let samples = 7

    static func nodes(changed: Bool) -> [AXNode] {
        (0..<nodeCount).map { index in
            let label = changed && index % 10 != 0 ? "changed-\(index)" : "item-\(index)"
            return AXNode(index: index, role: "AXButton", label: label, frame: nil,
                          actions: [], depth: 1, enabled: true)
        }
    }

    static func median(_ values: [Double]) -> Double {
        values.sorted()[values.count / 2]
    }

    static func cpuMilliseconds() -> Double {
        var usage = rusage()
        precondition(getrusage(RUSAGE_SELF, &usage) == 0)
        let user = Double(usage.ru_utime.tv_sec) * 1_000 + Double(usage.ru_utime.tv_usec) / 1_000
        let system = Double(usage.ru_stime.tv_sec) * 1_000 + Double(usage.ru_stime.tv_usec) / 1_000
        return user + system
    }

    static func run(_ name: String, base: [AXNode], current: [AXNode]) {
        var timings: [Double] = []
        var checksum = 0
        for _ in 0..<samples {
            let start = cpuMilliseconds()
            for _ in 0..<repeats {
                let diff = AXSnapshotDiff.diff(base: base, current: current, baseSnapshotID: "base")
                checksum &+= diff.unchangedCount &+ diff.added.count &+ diff.removed.count
            }
            let elapsed = cpuMilliseconds() - start
            timings.append(elapsed)
        }
        let rendered = timings.map { String(format: "%.3f", $0) }.joined(separator: ",")
        print("\(name): median_cpu_ms=\(String(format: "%.3f", median(timings))) samples_cpu_ms=[\(rendered)] checksum=\(checksum)")
    }

    static func main() {
        let base = nodes(changed: false)
        run("identical", base: base, current: base)
        run("90pct_changed_keys", base: base, current: nodes(changed: true))
        var usage = rusage()
        if getrusage(RUSAGE_SELF, &usage) == 0 {
            print("peak_rss_bytes=\(usage.ru_maxrss)")
        }
    }
}
