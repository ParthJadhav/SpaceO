// Benchmark the production BoundedLineReader with synthetic fixture files.
// Extract the reader class from MCPServer.swift to /tmp/reader.swift (Foundation + Darwin
// imports), then compile it with Sources/SpaceOMCP/MCPInputLine.swift and this driver using
// swiftc -O. See docs/AGENT_EFFICIENCY.md AE-183 through AE-185 for fixture definitions.
import Foundation

@main struct FramingBenchmark {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 5, let iterations = Int(args[2]), (1...1_000).contains(iterations),
              let expectedLines = Int(args[3]), (0...1_000_000).contains(expectedLines),
              let expectedErrors = Int(args[4]), (0...1_000_000).contains(expectedErrors) else {
            FileHandle.standardError.write(Data("usage: benchmark path iterations lines-per-file errors-per-file\n".utf8))
            exit(2)
        }
        let path = args[1]
        var lines = 0
        var errors = 0
        let start = ContinuousClock.now
        for _ in 0..<iterations {
         try autoreleasepool {
          let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
          defer { try? handle.close() }
          let reader = BoundedLineReader(handle: handle)
          while true {
           do {
            guard try reader.nextInputLine() != nil else { break }
            lines += 1
           } catch BoundedLineReader.ReaderError.lineTooLong { errors += 1 }
          }
         }
        }
        precondition(lines == expectedLines * iterations && errors == expectedErrors * iterations)
        let elapsed = start.duration(to: .now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        print("lines=\(lines) errors=\(errors) seconds=\(seconds)")
    }
}
