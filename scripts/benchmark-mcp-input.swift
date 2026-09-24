// Synthetic MCP input preparation plus Foundation JSON parsing; no daemon or host app access.
// swiftc -O Sources/SpaceOMCP/MCPInputLine.swift scripts/benchmark-mcp-input.swift -o /tmp/spaceo-mcp-input
// /usr/bin/time -l /tmp/spaceo-mcp-input original ascii 1048000 200
// /usr/bin/time -l /tmp/spaceo-mcp-input bytes ascii 1048000 200
// Use unicode instead of ascii to measure the compatibility fallback.
import Foundation

@main struct Benchmark {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 5, ["original", "bytes"].contains(args[1]),
              ["ascii", "unicode"].contains(args[2]),
              let size = Int(args[3]), (1...1_048_000).contains(size),
              let iterations = Int(args[4]), (1...100_000).contains(iterations) else {
            FileHandle.standardError.write(Data("usage: benchmark original|bytes ascii|unicode size iterations\n".utf8))
            exit(2)
        }
        let text = args[2] == "ascii" ? String(repeating: "a", count: size)
            : String(repeating: "é", count: size / 2)
        let data = Data(("{\"text\":\"" + text + "\"}").utf8)
        var parsed = 0
        let start = ContinuousClock.now
        for _ in 0..<iterations {
            try autoreleasepool {
                let object: Any
                if args[1] == "original" {
                    let line = String(data: data, encoding: .utf8)!
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    object = try JSONSerialization.jsonObject(with: trimmed.data(using: .utf8)!)
                } else {
                    object = try MCPInputLine(data: data)!.jsonObject()!
                }
                // Check object shape without walking all decoded graphemes a second time.
                precondition((object as? [String: Any])?.count == 1)
                parsed += 1
            }
        }
        precondition(parsed == iterations)
        let elapsed = start.duration(to: .now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        print("mode=\(args[1]) alphabet=\(args[2]) bytes=\(data.count) iterations=\(iterations) seconds=\(seconds)")
    }
}
