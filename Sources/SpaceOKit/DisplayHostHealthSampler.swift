import Foundation
import Darwin

/// Fixed, read-only kernel/process queries and bounded diagnostic metadata. No Python, shell,
/// WindowServer calls, report contents, process names or paths in the public report.
enum DisplayHostHealthSampler {
    static let services = ["/usr/libexec/colorsync.displayservices", "/usr/libexec/colorsyncd"]
    /// Whole capture budget; below the monitor's three-second in-flight watchdog.
    static let captureBudget: TimeInterval = 2.5
    private typealias Unknown = DisplayHostHealthSample.Unknown
    typealias Reader = (_ executable: String, _ arguments: [String], _ timeout: TimeInterval) throws -> String

    /// One overall deadline; every helper and the metadata scan get only what remains.
    struct Deadline {
        let end: TimeInterval
        let clock: () -> TimeInterval
        init(budget: TimeInterval = captureBudget,
             clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
            self.clock = clock
            end = clock() + budget
        }

        func remaining(atMost limit: TimeInterval = .infinity) throws -> TimeInterval {
            let left = end - clock()
            guard left.isFinite, left > 0 else { throw Unknown("host_health_capture_budget") }
            return min(left, limit)
        }
    }

    struct ProcessRow: Sendable, Equatable {
        let pid: Int32
        let start: String
        let cpuSeconds: Double
    }

    struct ServiceObservation {
        /// Timestamp of the final process read, before slower launchd reconciliation.
        let uptime: TimeInterval
        let services: [String: DisplayHostHealthSample.Service]
    }

    enum LaunchdRecord: Equatable {
        case running(pid: Int32, launches: UInt64)
        case idle(launches: UInt64)
    }

    static func capture(deadline: Deadline = Deadline()) throws -> DisplayHostHealthSample {
        var pressure: UInt32 = 0
        var pressureSize = MemoryLayout.size(ofValue: pressure)
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pressureSize, nil, 0) == 0,
              pressureSize == MemoryLayout.size(ofValue: pressure) else { throw Unknown("memory_pressure_unreadable") }
        var boot = timeval()
        var bootSize = MemoryLayout.size(ofValue: boot)
        guard sysctlbyname("kern.boottime", &boot, &bootSize, nil, 0) == 0,
              bootSize == MemoryLayout.size(ofValue: boot) else { throw Unknown("boot_time") }
        let now = Date().timeIntervalSince1970
        guard boot.tv_sec > 0, Double(boot.tv_sec) <= now else { throw Unknown("boot_time") }

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
        guard result == KERN_SUCCESS, count == expectedCount else { throw Unknown("vm_statistics") }
        let reports: Int
        let metadataTimeout = try deadline.remaining(atMost: 1)
        do { reports = try diagnosticReports(
            roots: [("/Library/Logs/DiagnosticReports", true),
                    (FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Library/Logs/DiagnosticReports").path, false)],
            since: min(Double(boot.tv_sec), now - 86_400), timeout: metadataTimeout)
        } catch { throw Unknown("windowserver_diagnostic_metadata") }
        let counters = try serviceSample(deadline: deadline)
        _ = try deadline.remaining()
        return .init(uptime: counters.uptime, pressure: pressure,
                     swapins: vm.swapins, swapouts: vm.swapouts, services: counters.services,
                     diagnosticReports: reports)
    }

    static func launchdLabel(_ service: String) -> String {
        "com.apple." + service.split(separator: "/").last.map(String.init)!
    }

    /// Process rows bracketed with two reads of both exact launchd jobs. A job may launch and
    /// exit without appearing in either process list, so both launch counts must also agree.
    static func serviceSample(
        deadline: Deadline,
        read: Reader = { try readHelper(executable: $0, arguments: $1, timeout: $2) }
    ) throws -> ServiceObservation {
        func processes() throws -> (rows: [String: ProcessRow], uptime: TimeInterval) {
            let timeout = try deadline.remaining()
            let text: String
            do { text = try read("/bin/ps", ["-axo", "pid=,lstart=,time=,comm="], timeout) }
            catch { throw Unknown("colorsync_process_list") }
            let uptime = deadline.clock()
            do { return (try parseServices(text), uptime) } catch { throw Unknown("colorsync_service_counter") }
        }
        let first = try processes().rows
        var records: [String: LaunchdRecord] = [:]
        for service in services {
            let timeout = try deadline.remaining()
            let text: String
            do { text = try read("/bin/launchctl", ["print", "system/" + launchdLabel(service)], timeout) }
            catch { throw Unknown("colorsync_launchd_unreadable") }
            records[service] = try launchdService(text, service: service)
        }
        let observation = try processes()
        let latest = observation.rows
        // Keep counters paired with their process observation. Subsequent launchctl latency
        // must not shorten or lengthen the interval used to calculate CPU consumption.
        for service in services {
            let timeout = try deadline.remaining()
            let text: String
            do { text = try read("/bin/launchctl", ["print", "system/" + launchdLabel(service)], timeout) }
            catch { throw Unknown("colorsync_launchd_unreadable") }
            guard try launchdService(text, service: service) == records[service] else {
                throw Unknown("colorsync_visibility_changed")
            }
        }
        _ = try deadline.remaining()
        var result: [String: DisplayHostHealthSample.Service] = [:]
        for service in services {
            switch records[service]! {
            case let .running(pid, launches):
                guard let old = first[service], let new = latest[service], old.pid == pid, new.pid == pid,
                      old.start == new.start, new.cpuSeconds >= old.cpuSeconds else {
                    throw Unknown("colorsync_visibility_changed")
                }
                result[service] = .running(pid: pid, start: new.start, cpuSeconds: new.cpuSeconds, launches: launches)
            case let .idle(launches):
                guard first[service] == nil, latest[service] == nil else { throw Unknown("colorsync_visibility_changed") }
                result[service] = .idle(launches: launches)
            }
        }
        return .init(uptime: observation.uptime, services: result)
    }

    /// Accepts only top-level fields of the exact job. Idle requires a recognized memory-idle
    /// exit or the never-started shape; failures, signals and other states are unknown.
    static func launchdService(_ text: String, service: String) throws -> LaunchdRecord {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard services.contains(service), text.utf8.count <= 1_048_576,
              lines.first == "system/" + launchdLabel(service) + " = {" else { throw Unknown("colorsync_launchd_record_invalid") }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() where line.hasPrefix("\t") && !line.hasPrefix("\t\t") {
            guard let separator = line.range(of: " = ") else { continue }
            let key = String(line[line.index(after: line.startIndex)..<separator.lowerBound])
            guard !key.isEmpty, !key.contains("="), !key.contains("\t") else { continue }
            guard fields[key] == nil else { throw Unknown("colorsync_launchd_record_invalid") }
            fields[key] = String(line[separator.upperBound...])
        }
        func number<T: FixedWidthInteger>(_ key: String, _: T.Type) throws -> T? {
            guard let raw = fields[key] else { return nil }
            guard !raw.isEmpty, raw.utf8.count <= 20, raw.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = T(raw) else { throw Unknown("colorsync_launchd_record_invalid") }
            return value
        }
        guard fields["program"] == service else { throw Unknown("colorsync_launchd_program_mismatch") }
        guard let launches = try number("runs", UInt64.self) else { throw Unknown("colorsync_launchd_record_invalid") }
        let pid = try number("pid", Int32.self)
        let idleExit = "JETSAM_REASON_MEMORY_IDLE_EXIT"
        switch fields["state"] {
        case "running":
            guard let pid, pid > 0, launches >= 1, [nil, "running"].contains(fields["job state"]) else { break }
            return .running(pid: pid, launches: launches)
        case "not running":
            guard pid == nil, fields["active count"] == "0", fields["last terminating signal"] == nil else { break }
            if launches >= 1, fields["last exit reason"] == idleExit, fields["last exit code"] == nil,
               [nil, idleExit].contains(fields["last jetsam exit details"]),
               [nil, "exited"].contains(fields["job state"]),
               (fields["properties"] ?? "").components(separatedBy: " | ").contains("supports pressured exit") {
                return .idle(launches: launches)
            }
            if launches == 0, fields["last exit code"] == "(never exited)", fields["last exit reason"] == nil,
               fields["last jetsam exit details"] == nil, fields["job state"] == nil {
                return .idle(launches: 0)
            }
        default: break
        }
        throw Unknown("colorsync_launchd_state_unsupported")
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

    static func parseServices(_ text: String) throws -> [String: ProcessRow] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 1_048_576 else { throw Unknown("colorsync_process_list_unavailable") }
        var counters: [String: ProcessRow] = [:]
        var sawProcess = false
        for line in text.split(separator: "\n") {
            // PID, five lstart fields, cumulative CPU, full executable path (possibly spaced).
            let fields = line.split(maxSplits: 7, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
            guard fields.count == 8 else {
                if services.contains(where: { line.hasSuffix($0) }) {
                    throw Unknown("colorsync_process_row_invalid")
                }
                continue
            }
            guard let listedPID = Int32(fields[0]), listedPID >= 0 else { throw Unknown("colorsync_process_row_invalid") }
            sawProcess = true
            guard services.contains(String(fields[7])) else { continue }
            let name = String(fields[7])
            guard counters[name] == nil, let pid = Int32(fields[0]), pid > 0 else { throw Unknown() }
            let start = fields[1...5].joined(separator: " ")
            counters[name] = .init(pid: pid, start: start, cpuSeconds: try cpuSeconds(String(fields[6])))
        }
        guard sawProcess else { throw Unknown("colorsync_process_list_unavailable") }
        // A successful full listing may contain neither on-demand service; launchd evidence
        // in serviceSample decides whether an absent service is a verified idle state.
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
