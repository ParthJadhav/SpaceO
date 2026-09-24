// Isolated typing-limit predicates used before/after the validation change.
// swiftc -O scripts/benchmark-string-admission.swift -o /tmp/spaceo-string-admission
// /tmp/spaceo-string-admission original combining 100
// /tmp/spaceo-string-admission bounded combining 100
// Other synthetic fixtures: ascii, emoji, scalar-overflow. No user/application input is sent.
import Foundation

@inline(never) func original(_ text: String) -> Bool {
    text.count <= 8_000 && text.unicodeScalars.count <= 8_000 && text.utf8.count <= 32_000
}
@inline(never) func bounded(_ text: String) -> Bool {
    text.utf8.count <= 32_000 && text.unicodeScalars.count <= 8_000
}
let args = CommandLine.arguments
guard args.count == 4, ["original", "bounded"].contains(args[1]),
      ["ascii", "emoji", "combining", "scalar-overflow"].contains(args[2]),
      let iterations = Int(args[3]), (1...1_000_000).contains(iterations) else {
    FileHandle.standardError.write(Data("usage: benchmark original|bounded ascii|emoji|combining|scalar-overflow iterations\n".utf8))
    exit(2)
}
let value: String
switch args[2] {
case "ascii": value = String(repeating: "a", count: 64)
case "emoji": value = String(repeating: "😀", count: 8_000)
case "combining": value = "a" + String(repeating: "\u{301}", count: 250_000)
default: value = String(repeating: "e\u{301}", count: 4_001)
}
let validate = args[1] == "original" ? original : bounded
let expected = args[2] == "ascii" || args[2] == "emoji"
var accepted = 0
let start = ContinuousClock.now
for _ in 0..<iterations { if validate(value) { accepted += 1 } }
let elapsed = start.duration(to: .now).components
let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
precondition(accepted == (expected ? iterations : 0))
print("fixture=\(args[2]) mode=\(args[1]) iterations=\(iterations) accepted=\(accepted) seconds=\(seconds)")
