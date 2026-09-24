// Standalone benchmark: swiftc -O scripts/benchmark-observation-rendering.swift \
//   Sources/SpaceOKit/AXObservationRendering.swift -o /tmp/benchmark-observation-rendering
// Then run /tmp/benchmark-observation-rendering. No package or live AX access is needed.
import CoreGraphics
import Dispatch
import Foundation

struct AXNode {
    let index: Int?
    let role: String
    let label: String
    let depth: Int
    let enabled: Bool
    let frame: CGRect? = nil

    func appendPreviousRenderedLine(to output: inout String, indented: Bool = false) {
        let indent = indented ? String(repeating: "  ", count: min(max(depth, 0), 12)) : ""
        let tag = index.map { "[\($0)] " } ?? ""
        let shortRole = role.replacingOccurrences(of: "AX", with: "")
        output += "\(indent)\(tag)\(shortRole)"
        if !label.isEmpty {
            output += " — "
            output += label
        }
        if !enabled { output += "  (disabled)" }
    }
}

@inline(never)
private func outline(_ nodes: [AXNode], previous: Bool) -> String {
    var result = ""
    for (position, node) in nodes.enumerated() {
        if position > 0 { result += "\n" }
        if previous {
            node.appendPreviousRenderedLine(to: &result, indented: true)
        } else {
            node.appendRenderedLine(to: &result, indented: true)
        }
    }
    return result
}

private func median(_ samples: [Double]) -> Double {
    let sorted = samples.sorted()
    return sorted[sorted.count / 2]
}

@main
struct Benchmark {
    static func main() {
        let nodes = (0..<4_000).map { index in
            let role: String
            switch index % 80 {
            case 0: role = "AXAXMenuAXItem" // Embedded prefixes use the compatibility path.
            case 1: role = "AX\u{0301}Button" // A combining mark must retain the old result.
            case 2: role = "AXFooAX\u{0301}Bar" // Embedded combining mark exercises the fast path.
            default: role = ["AXButton", "AXTextField", "AXStaticText", "AXMenuItem"][index % 4]
            }
            return AXNode(index: index, role: role,
                          label: "Element \(index) — sample accessibility value",
                          depth: index % 5, enabled: index % 9 != 0)
        }

        let previous = outline(nodes, previous: true)
        let current = outline(nodes, previous: false)
        guard previous.utf8.elementsEqual(current.utf8) else {
            fputs("Previous and current output differ\n", stderr)
            exit(1)
        }

        for _ in 0..<10 {
            _ = outline(nodes, previous: true)
            _ = outline(nodes, previous: false)
        }
        var previousSamples: [Double] = []
        var currentSamples: [Double] = []
        var checksum = 0
        for sample in 0..<41 {
            for previous in (sample.isMultiple(of: 2) ? [true, false] : [false, true]) {
                let start = DispatchTime.now().uptimeNanoseconds
                for _ in 0..<20 {
                    checksum &+= outline(nodes, previous: previous).utf8.count
                }
                let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 20_000_000
                if previous { previousSamples.append(milliseconds) }
                else { currentSamples.append(milliseconds) }
            }
        }
        let oldMedian = median(previousSamples)
        let newMedian = median(currentSamples)
        print("nodes=\(nodes.count) bytes=\(previous.utf8.count) output_equal=true checksum=\(checksum)")
        print(String(format: "previous_median_ms=%.3f current_median_ms=%.3f speedup=%.2fx",
                     oldMedian, newMedian, oldMedian / newMedian))
    }
}
