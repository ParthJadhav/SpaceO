import Foundation
import Darwin

/// Fixed, read-only kernel/process queries and bounded diagnostic metadata. No Python, shell,
/// WindowServer calls, report contents, process names or paths in the public report.
enum DisplayHostHealthSampler {
    static let services = ["/usr/libexec/colorsync.displayservices", "/usr/libexec/colorsyncd"]
    private typealias Unknown = DisplayHostHealthSample.Unknown

    static func capture() throws -> DisplayHostHealthSample {
        var pressure: UInt32 = 0
        var pressureSize = MemoryLayout.size(ofValue: pressure)
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pressureSize, nil, 0) == 0,
              pressureSize == MemoryLayout.size(ofValue: pressure) else { throw Unknown() }
        var boot = timeval()
        var bootSize = MemoryLayout.size(ofValue: boot)
        guard sysctlbyname("kern.boottime", &boot, &bootSize, nil, 0) == 0,
              bootSize == MemoryLayout.size(ofValue: boot) else { throw Unknown() }
        let now = Date().timeIntervalSince1970
        guard boot.tv_sec > 0, Double(boot.tv_sec) <= now else { throw Unknown() }

        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: vm) / MemoryLayout<integer_t>.size)
        let expectedCount = count
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS, count == expectedCount else { throw Unknown() }
        let reports = try diagnosticReports(
            roots: [("/Library/Logs/DiagnosticReports", true),
                    (FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Library/Logs/DiagnosticReports").path, false)],
            since: min(Double(boot.tv_sec), now - 86_400))
        let counters = try parseServices(readProcessList())
        return .init(uptime: ProcessInfo.processInfo.systemUptime, pressure: pressure,
                     swapins: vm.swapins, swapouts: vm.swapouts, services: counters,
                     diagnosticReports: reports)
    }

    static func cpuSeconds(_ text: String) throws -> Double {
        guard !text.isEmpty, text.utf8.count <= 64 else { throw Unknown() }
        let dayParts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard (1...2).contains(dayParts.count) else { throw Unknown() }
        let days: Double
        if dayParts.count == 2 {
            guard let value = UInt(dayParts[0]) else { throw Unknown() }
            days = Double(value)
        } else { days = 0 }
        let parts = dayParts.last!.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), let seconds = Double(parts.last!),
              seconds.isFinite, seconds >= 0, seconds < 60,
              let minutes = UInt(parts[parts.count - 2]) else { throw Unknown() }
        var hours: UInt = 0
        if parts.count == 3 {
            guard let value = UInt(parts[0]), minutes < 60 else { throw Unknown() }
            hours = value
        }
        let value = days * 86_400 + Double(hours) * 3_600 + Double(minutes) * 60 + seconds
        guard value.isFinite else { throw Unknown() }
        return value
    }

    static func parseServices(_ text: String) throws -> [String: DisplayHostHealthSample.Service] {
        guard text.utf8.count <= 1_048_576 else { throw Unknown() }
        var counters: [String: DisplayHostHealthSample.Service] = [:]
        for line in text.split(separator: "\n") {
            // PID, five lstart fields, cumulative CPU, full executable path (possibly spaced).
            let fields = line.split(maxSplits: 7, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
            guard fields.count == 8, services.contains(String(fields[7])) else { continue }
            let name = String(fields[7])
            guard counters[name] == nil, let pid = Int32(fields[0]), pid > 0 else { throw Unknown() }
            let start = fields[1...5].joined(separator: " ")
            counters[name] = .init(pid: pid, start: start, cpuSeconds: try cpuSeconds(String(fields[6])))
        }
        guard Set(counters.keys) == Set(services) else { throw Unknown() }
        return counters
    }

    static func diagnosticReports(roots: [(String, Bool)], since: TimeInterval,
                                  maximumEntries: Int = 10_000, timeout: TimeInterval = 1) throws -> Int {
        guard since.isFinite else { throw Unknown() }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var scanned = 0, reports = 0
        for (root, required) in roots {
            for (path, mustExist) in [(root, required), (root + "/Retired", false)] {
                var info = stat()
                if lstat(path, &info) != 0 {
                    if errno == ENOENT && !mustExist { continue }
                    throw Unknown()
                }
                guard info.st_mode & S_IFMT == S_IFDIR, let directory = opendir(path) else { throw Unknown() }
                defer { closedir(directory) }
                while true {
                    errno = 0
                    guard let entry = readdir(directory) else {
                        guard errno == 0 else { throw Unknown() }
                        break
                    }
                    scanned += 1
                    guard scanned <= maximumEntries, ProcessInfo.processInfo.systemUptime < deadline else { throw Unknown() }
                    let name = withUnsafeBytes(of: entry.pointee.d_name) {
                        String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
                    }
                    guard name.hasPrefix("WindowServer-") || name.hasPrefix("WindowServer_") else { continue }
                    guard [".ips", ".spin", ".crash", ".diag", ".hang"].contains(where: name.hasSuffix) else { continue }
                    guard fstatat(dirfd(directory), name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                          info.st_mode & S_IFMT == S_IFREG else { throw Unknown() }
                    if Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9 >= since {
                        reports += 1
                    }
                }
            }
        }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw Unknown() }
        return reports
    }

    private static func readProcessList() throws -> String {
        try readHelper(executable: "/bin/ps", arguments: ["-axo", "pid=,lstart=,time=,comm="])
    }

    // Injectable command only inside the module, for inert process/pipe regression fixtures.
    static func readHelper(executable: String, arguments: [String], timeout: TimeInterval = 2,
                           maximumBytes: Int = 1_048_576) throws -> String {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) { _, value in value }
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
            // Only the fixed read-only helper is eligible for termination, never a display owner.
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        let fd = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw Unknown() }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        try pipe.fileHandleForWriting.close()
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        var eof = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            if !eof {
                let count = read(fd, &buffer, buffer.count)
                if count > 0 {
                    guard count <= maximumBytes - data.count else { throw Unknown() }
                    data.append(contentsOf: buffer.prefix(count))
                    continue
                }
                if count == 0 { eof = true }
                else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { throw Unknown() }
            }
            if eof, !process.isRunning {
                guard process.terminationReason == .exit, process.terminationStatus == 0,
                      let output = String(data: data, encoding: .utf8) else { throw Unknown() }
                return output
            }
            usleep(2_000)
        }
        throw Unknown()
    }
}
