// Compile with the before/after BoundedDiagnosticText source. Define BEFORE for old source.
// swiftc -O [-D BEFORE] /tmp/prefix.swift scripts/benchmark-diagnostic-prefix.swift -o /tmp/prefix
// /tmp/prefix small|ascii|grapheme|log-grapheme iterations
import Foundation

@main struct DiagnosticPrefixBenchmark {
    @inline(never) static func clip(_ value: String, log: Bool) -> String {
        if log {
            #if BEFORE
            return BoundedDiagnosticText.prefix(value.prefix(4096), maximumBytes: 16384)
            #else
            return BoundedDiagnosticText.prefix(value, maximumBytes: 16384, maximumCharacters: 4096)
            #endif
        }
        return BoundedDiagnosticText.prefix(value, maximumBytes: 480)
    }

    static func main() {
        let args = CommandLine.arguments
        guard args.count == 3, let iterations = Int(args[2]), (1...1_000_000).contains(iterations) else {
            fatalError("usage: benchmark fixture iterations")
        }
        let value: String
        switch args[1] {
        case "small": value = "synthetic title"
        case "ascii": value = String(repeating: "x", count: 2000)
        case "grapheme", "log-grapheme": value = "a" + String(repeating: "\u{301}", count: 250_000)
        default: fatalError("unknown fixture")
        }
        let log = args[1] == "log-grapheme"
        let expected = args[1] == "small" ? value : args[1] == "ascii" ? String(repeating: "x", count: 477) + "…" : "…"
        precondition(clip(value, log: log) == expected)
        var checksum = 0
        let start = ContinuousClock.now
        for _ in 0..<iterations {
            checksum += autoreleasepool { clip(value, log: log).utf8.count }
        }
        precondition(checksum == expected.utf8.count * iterations)
        let elapsed = start.duration(to: .now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        print("fixture=\(args[1]) iterations=\(iterations) checksum=\(checksum) seconds=\(seconds)")
    }
}
