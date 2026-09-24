// Isolated synthetic transport-validation benchmark; no screenshot or host application access.
// Compile the production helper with this driver:
// swiftc -O Sources/SpaceOMCP/PNGBase64.swift scripts/benchmark-png-validation.swift -o /tmp/spaceo-png-benchmark
// Run each variant in a separate process for comparable peak RSS:
// /usr/bin/time -l /tmp/spaceo-png-benchmark original 5242880 200
// /usr/bin/time -l /tmp/spaceo-png-benchmark bounded 5242880 200
// The fixture has a PNG signature and synthetic bytes, not a renderable PNG image.
import Foundation

@inline(never) func original(_ value: String, maximumBytes: Int) -> Bool {
    guard value.utf8.count <= 7 * 1_048_576,
          let data = Data(base64Encoded: value), data.count <= maximumBytes,
          data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { return false }
    return true
}
@inline(never) func bounded(_ value: String, maximumBytes: Int) -> Bool {
    PNGBase64.isValid(value, maximumDecodedBytes: maximumBytes)
}

@main
struct PNGValidationBenchmark {
    static func main() {
        guard CommandLine.arguments.count == 4,
              ["original", "bounded"].contains(CommandLine.arguments[1]),
              let size = Int(CommandLine.arguments[2]), (12...5 * 1_048_576).contains(size),
              let iterations = Int(CommandLine.arguments[3]), (1...100_000).contains(iterations) else {
            fatalError("usage: benchmark original|bounded decoded-bytes iterations (12...5242880 bytes)")
        }
        let mode = CommandLine.arguments[1]
        let encodedCount = ((size + 2) / 3) * 4
        let encoded = String(unsafeUninitializedCapacity: encodedCount) { buffer in
            buffer.initialize(repeating: 65)
            for (index, byte) in "iVBORw0KGgoA".utf8.enumerated() { buffer[index] = byte }
            let padding = (3 - size % 3) % 3
            for index in (encodedCount - padding)..<encodedCount { buffer[index] = 61 }
            return encodedCount
        }
        let validate = mode == "original" ? original : bounded
        var accepted = 0
        let start = ContinuousClock.now
        for _ in 0..<iterations {
            if autoreleasepool(invoking: { validate(encoded, size) }) { accepted += 1 }
        }
        let elapsed = start.duration(to: .now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        precondition(accepted == iterations)
        print("mode=\(mode) bytes=\(size) iterations=\(iterations) seconds=\(seconds)")
    }
}
