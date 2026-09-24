// Synthetic diagnostic construction with the production helper; no daemon or user data.
// swiftc -O Sources/SpaceOMCP/MCPDiagnostic.swift scripts/benchmark-mcp-diagnostics.swift -o /tmp/spaceo-mcp-diagnostics
// /usr/bin/time -l /tmp/spaceo-mcp-diagnostics original many 100
// /usr/bin/time -l /tmp/spaceo-mcp-diagnostics bounded many 100
// Other fixtures: valid, typo, giant.
import Foundation

@main struct DiagnosticBenchmark {
    static func main() {
        let args = CommandLine.arguments
        guard args.count == 4, ["original", "bounded"].contains(args[1]),
              ["valid", "typo", "many", "giant"].contains(args[2]),
              let iterations = Int(args[3]), (1...1_000_000).contains(iterations) else {
            FileHandle.standardError.write(Data("usage: benchmark original|bounded valid|typo|many|giant iterations\n".utf8))
            exit(2)
        }
        let allowed: Set<String> = args[2] == "giant" ? [] : ["session", "text", "web"]
        let keys: [String]
        switch args[2] {
        case "valid": keys = ["session", "text", "web"]
        case "typo": keys = ["session", "txet", "web"]
        case "many": keys = (0..<20_000).map { String(format: "extra_%05d", $0) }
        default: keys = ["a" + String(repeating: "\u{301}", count: 250_000)]
        }
        let arguments = Dictionary(uniqueKeysWithValues: keys.map { ($0, 0) })
        var bytes = 0
        var errors = 0
        let start = ContinuousClock.now
        for _ in 0..<iterations {
            autoreleasepool {
                let diagnostic: String?
                if args[1] == "original" {
                    let unexpected = Set(arguments.keys).subtracting(allowed)
                    diagnostic = unexpected.isEmpty ? nil
                        : "unexpected argument(s): " + unexpected.sorted().joined(separator: ", ")
                } else {
                    diagnostic = MCPDiagnostic.unexpected(arguments.keys, allowed: allowed)
                }
                if let diagnostic { errors += 1; bytes = diagnostic.utf8.count }
            }
        }
        precondition(errors == (args[2] == "valid" ? 0 : iterations))
        let elapsed = start.duration(to: .now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        print("mode=\(args[1]) fixture=\(args[2]) iterations=\(iterations) bytes=\(bytes) seconds=\(seconds)")
    }
}
