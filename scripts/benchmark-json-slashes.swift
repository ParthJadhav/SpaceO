// Isolated Foundation JSONEncoder benchmark using SpaceO's response field names.
// No screenshot, daemon, or host application access; fixtures are synthetic encoded text.
// swiftc -O scripts/benchmark-json-slashes.swift -o /tmp/spaceo-json-slashes
// /usr/bin/time -l /tmp/spaceo-json-slashes escaped uniform 200
// /usr/bin/time -l /tmp/spaceo-json-slashes literal uniform 200
// Repeat with "slashes" for the worst-case alphabet distribution.
import Foundation

struct Payload: Encodable { let ok: Bool; let imageBase64: String }
let args = CommandLine.arguments
guard args.count == 4, ["escaped", "literal"].contains(args[1]),
       ["uniform", "slashes"].contains(args[2]),
       let iterations = Int(args[3]), (1...10_000).contains(iterations) else {
    FileHandle.standardError.write(Data("usage: benchmark escaped|literal uniform|slashes iterations\n".utf8))
    exit(2)
}
let count = ((5 * 1_048_576 + 2) / 3) * 4
let alphabet = Array((args[2] == "uniform"
    ? "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/" : "/").utf8)
let value = String(unsafeUninitializedCapacity: count) { buffer in
    for index in 0..<count { buffer[index] = alphabet[index % alphabet.count] }
    buffer[count - 2] = 56 // Canonical final pad bits for two decoded bytes.
    buffer[count - 1] = 61
    return count
}
let payload = Payload(ok: true, imageBase64: value)
let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
if args[1] == "literal" { encoder.outputFormatting = [.withoutEscapingSlashes] }
var encodedBytes = 0
let start = ContinuousClock.now
for _ in 0..<iterations {
    encodedBytes = try autoreleasepool { try encoder.encode(payload).count }
}
let elapsed = start.duration(to: .now).components
let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
print("mode=\(args[1]) distribution=\(args[2]) iterations=\(iterations) bytes=\(encodedBytes) seconds=\(seconds)")
