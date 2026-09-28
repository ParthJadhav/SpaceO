// Read-only, bounded process sampling. No process names, paths, contents, or credentials.
// swiftc -O scripts/process-resources.swift -o .build/process-resources
// .build/process-resources PID SAMPLES INTERVAL_SECONDS
// .build/process-resources --self-test
import Darwin
import Foundation

struct Sample: Codable {
    let cpuUserSeconds: Double
    let cpuSystemSeconds: Double
    let residentBytes: UInt64
    let physicalFootprintBytes: UInt64
    let idleWakeups: UInt64
    let interruptWakeups: UInt64
    let pageins: UInt64
    let startTicks: UInt64
}
var timebase = mach_timebase_info_data_t()
guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom > 0 else { exit(1) }
// libproc's task CPU counters use Mach absolute ticks, not nanoseconds on Apple Silicon.
let secondsPerTick = Double(timebase.numer) / Double(timebase.denom) / 1e9
func capture(_ pid: Int32) throws -> Sample {
    var usage = rusage_info_v0()
    let result = withUnsafeMutablePointer(to: &usage) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V0, $0)
        }
    }
    guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    return Sample(cpuUserSeconds: Double(usage.ri_user_time) * secondsPerTick,
                  cpuSystemSeconds: Double(usage.ri_system_time) * secondsPerTick,
                  residentBytes: usage.ri_resident_size, physicalFootprintBytes: usage.ri_phys_footprint,
                  idleWakeups: usage.ri_pkg_idle_wkups, interruptWakeups: usage.ri_interrupt_wkups,
                  pageins: usage.ri_pageins, startTicks: usage.ri_proc_start_abstime)
}
func cpuSeconds() -> Double {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return .nan }
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
}
let args = CommandLine.arguments
if args.count == 2, args[1] == "--self-test" {
    let before = try capture(getpid()), cpuBefore = cpuSeconds()
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(150))
    var checksum: UInt64 = 0
    while ContinuousClock.now < deadline { checksum &+= mach_absolute_time() }
    let cpuDelta = cpuSeconds() - cpuBefore, after = try capture(getpid())
    let sampled = after.cpuUserSeconds + after.cpuSystemSeconds - before.cpuUserSeconds - before.cpuSystemSeconds
    guard cpuDelta > 0, abs(sampled / cpuDelta - 1) < 0.1, checksum != 0,
          after.residentBytes > 0, after.physicalFootprintBytes > 0 else {
        fputs("process-resource counter calibration failed\n", stderr); exit(1)
    }
    print("process-resource counter calibration passed")
    exit(0)
}
guard args.count == 4, let pid = Int32(args[1]), pid > 0,
      let count = Int(args[2]), (1...600).contains(count),
      let interval = Double(args[3]), interval.isFinite, (0.1...5).contains(interval),
      Double(count) * interval <= 1800 else {
    fputs("usage: process-resources PID SAMPLES(1...600) INTERVAL(0.1...5); maximum 30 minutes\n", stderr)
    exit(2)
}
struct Record: Encodable { let elapsedSeconds: Double; let sample: Sample }
let started = ContinuousClock.now
let encoder = JSONEncoder()
var identity: UInt64?
for index in 0..<count {
    do {
        let sample = try capture(pid)
        if let identity, identity != sample.startTicks {
            fputs("process identity changed; sampling stopped\n", stderr); exit(1)
        }
        identity = sample.startTicks
        let elapsed = started.duration(to: .now).components
        let record = Record(elapsedSeconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
                            sample: sample)
        var data = try encoder.encode(record); data.append(10)
        try FileHandle.standardOutput.write(contentsOf: data)
    } catch {
        fputs("process resource sample unavailable; sampling stopped\n", stderr); exit(1)
    }
    if index + 1 < count { Thread.sleep(forTimeInterval: interval) }
}
