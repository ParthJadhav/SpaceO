// Compile with the production Transport.LineBuffer extracted inside a Transport enum,
// plus TransportError.malformed(String), Foundation and Darwin imports. No socket or GUI.
// swiftc -O /tmp/event-buffer.swift scripts/benchmark-event-buffer.swift -o /tmp/event-buffer
// /usr/bin/time -l /tmp/event-buffer 8388608 20 fragmented
// /usr/bin/time -l /tmp/event-buffer 256 100000 single
// /usr/bin/time -l /tmp/event-buffer 256 100000 coalesced
import Foundation

@main struct EventBufferBenchmark {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 4, let size = Int(args[1]), (1...8_388_608).contains(size),
              let count = Int(args[2]), (1...100_000).contains(count),
              ["fragmented", "single", "coalesced"].contains(args[3]) else {
            fatalError("usage: benchmark bytes frames fragmented|single|coalesced")
        }
        let mode = args[3]
        // Match receiveResponses' [UInt8] read scratch and ArraySlice chunks.
        let fragment = [UInt8](repeating: 120, count: min(size, 8192))
        var frame: [UInt8] = mode == "fragmented" ? [] : [UInt8](repeating: 120, count: size)
        if mode != "fragmented" { frame.append(10) }
        let start = ContinuousClock.now
        var checksum = 0
        for _ in 0..<count {
            checksum += try autoreleasepool {
                var buffer = Transport.LineBuffer(maximumBytes: size)
                if mode == "fragmented" {
                    var remaining = size
                    while remaining > 0 {
                        let length = min(remaining, fragment.count)
                        try buffer.append(fragment.prefix(length))
                        precondition(buffer.nextLine() == nil)
                        remaining -= length
                    }
                    try buffer.append([10])
                } else {
                    try buffer.append(frame[...])
                    if mode == "coalesced" { try buffer.append(frame[...]) }
                }
                var bytes = 0
                while let line = buffer.nextLine() {
                    precondition(line.count == size && line.first == 120 && line.last == 120)
                    bytes += line.count
                }
                precondition(bytes == size * (mode == "coalesced" ? 2 : 1))
                return bytes
            }
        }
        let elapsed = start.duration(to: .now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        print("mode=\(mode) bytes=\(size) frames=\(count) checksum=\(checksum) seconds=\(seconds)")
    }
}
