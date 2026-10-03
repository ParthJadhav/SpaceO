#!/usr/bin/env python3
"""Read-only admission check for reserved-host live tests; never resets or kills services."""
import json
from datetime import datetime, timezone
import math
import os
from pathlib import Path
import re
import selectors
import stat
import subprocess
import sys
import time

SERVICES = ("/usr/libexec/colorsync.displayservices", "/usr/libexec/colorsyncd")
MAX_OUTPUT = 1024 * 1024
MAX_DIAGNOSTIC_ENTRIES = 10000
# Whole snapshot budget, mirroring the native sampler; each helper gets only what remains.
SNAPSHOT_BUDGET = 2.5
IDLE_EXIT = "JETSAM_REASON_MEMORY_IDLE_EXIT"


def read_command(command, until=None):
    """Bound diagnostic helpers, which own no displays, by bytes and elapsed time."""
    deadline = time.monotonic() + 3
    if until is not None:
        deadline = min(deadline, until)
        if deadline - time.monotonic() <= 0:
            raise ValueError("snapshot exceeded budget")
    child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             env=dict(os.environ, LC_ALL="C"))
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(child.stdout, selectors.EVENT_READ)
            data = bytearray()
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not selector.select(remaining):
                    raise ValueError("diagnostic helper timed out")
                chunk = os.read(child.stdout.fileno(), min(65536, MAX_OUTPUT + 1 - len(data)))
                if not chunk:
                    if child.wait(timeout=max(.001, deadline-time.monotonic())) != 0:
                        raise ValueError("diagnostic helper failed")
                    return data.decode("utf-8", errors="strict")
                data.extend(chunk)
                if len(data) > MAX_OUTPUT:
                    raise ValueError("diagnostic helper exceeded output budget")
    finally:
        child.stdout.close()
        if child.poll() is None:
            child.kill()
            # Even shutdown of a read-only helper must not introduce an unbounded wait.
            child.wait(timeout=1)


def cpu_seconds(value):
    match = re.fullmatch(r"(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+(?:\.\d+)?)", value)
    if not match:
        raise ValueError("invalid CPU counter")
    days, hours, minutes, seconds = (float(v or 0) for v in match.groups())
    result = days*86400 + hours*3600 + minutes*60 + seconds
    if not math.isfinite(result) or seconds >= 60:
        raise ValueError("invalid CPU counter")
    return result


def parse_services(text):
    if not text.strip() or len(text.encode("utf-8")) > MAX_OUTPUT:
        raise ValueError("process list unavailable")
    result = {}
    saw_process = False
    for line in text.splitlines():
        parts = line.split(None, 2)
        if len(parts) != 3:
            if any(line.endswith(service) for service in SERVICES):
                raise ValueError("invalid service row")
            continue
        if not parts[0].isdecimal():
            raise ValueError("invalid process row")
        saw_process = True
        if parts[2] not in SERVICES:
            continue
        pid, counter, service = parts
        if service in result or not pid.isdecimal() or int(pid) <= 0:
            raise ValueError("ambiguous service identity")
        result[service] = (int(pid), cpu_seconds(counter))
    if not saw_process:
        raise ValueError("process list unavailable")
    return result


def launchd_label(service):
    return "com.apple." + service.rsplit("/", 1)[1]


def launchd_service(text, service):
    """Return (pid or None, launches) from top-level fields of the exact launchd job only.

    Idle requires a recognized memory-idle exit or the never-started shape; failures,
    signals, exit codes and other states are unknown rather than guessed idle."""
    lines = text.split("\n")
    if (service not in SERVICES or len(text.encode("utf-8")) > MAX_OUTPUT
            or lines[0] != "system/" + launchd_label(service) + " = {"):
        raise ValueError("service record invalid")
    fields = {}
    for line in lines[1:]:
        match = re.fullmatch(r"\t([^\t=]+?) = (.*)", line)
        if not match:
            continue
        key, value = match.groups()
        if key in fields:
            raise ValueError("ambiguous service record")
        fields[key] = value

    def number(key):
        raw = fields.get(key)
        if raw is not None and not re.fullmatch(r"[0-9]{1,20}", raw):
            raise ValueError("service record invalid")
        return None if raw is None else int(raw)

    if fields.get("program") != service:
        raise ValueError("service program mismatch")
    runs, pid = number("runs"), number("pid")
    if runs is None or runs >= 2**64 or (pid is not None and pid >= 2**31):
        raise ValueError("service record invalid")
    state = fields.get("state")
    if state == "running":
        if pid and runs >= 1 and fields.get("job state") in (None, "running"):
            return (pid, runs)
    elif (state == "not running" and pid is None and fields.get("active count") == "0"
            and "last terminating signal" not in fields):
        if (runs >= 1 and fields.get("last exit reason") == IDLE_EXIT
                and "last exit code" not in fields
                and fields.get("last jetsam exit details", IDLE_EXIT) == IDLE_EXIT
                and fields.get("job state") in (None, "exited")
                and "supports pressured exit" in fields.get("properties", "").split(" | ")):
            return (None, runs)
        if (runs == 0 and fields.get("last exit code") == "(never exited)"
                and not {"last exit reason", "last jetsam exit details", "job state"} & set(fields)):
            return (None, 0)
    raise ValueError("service state unsupported")


def service_sample(until):
    """Read both launchd jobs around the final process snapshot. A launch and exit may
    be absent from both process lists, so the job identities/counts must also agree."""
    command = ["/bin/ps", "-axo", "pid=,time=,comm="]
    first = parse_services(read_command(command, until))
    records = {name: launchd_service(read_command(
        ["/bin/launchctl", "print", "system/" + launchd_label(name)], until), name) for name in SERVICES}
    latest = parse_services(read_command(command, until))
    for name in SERVICES:
        final = launchd_service(read_command(
            ["/bin/launchctl", "print", "system/" + launchd_label(name)], until), name)
        if final != records[name]:
            raise ValueError("service changed during sampling")
    if time.monotonic() >= until:
        raise ValueError("snapshot exceeded budget")
    result = {}
    for name, (pid, runs) in records.items():
        if pid is None:
            if name in first or name in latest:
                raise ValueError("service changed during sampling")
            result[name] = (None, None, runs)
            continue
        if (name not in first or name not in latest or first[name][0] != pid
                or latest[name][0] != pid or latest[name][1] < first[name][1]):
            raise ValueError("service changed during sampling")
        result[name] = (pid, latest[name][1], runs)
    return result


def diagnostic_cutoff(boot_text, now):
    values = re.findall(r"\bsec\s*=\s*(\d+)\b", boot_text)
    if len(values) != 1 or not math.isfinite(now) or not 0 < int(values[0]) <= now:
        raise ValueError("boot time unavailable")
    # A restart must not immediately erase the admission warning. Keep the whole current
    # boot, or the last 24 hours when that is longer. This is not an automatic recovery gate.
    return min(int(values[0]), now - 24 * 3600)


def windowserver_diagnostics(roots, since):
    """Count recent report metadata only; never read or emit diagnostic contents/names."""
    count = scanned = 0
    deadline = time.monotonic() + 3
    for root, required in roots:
        for directory, must_exist in ((root, required), (root / "Retired", False)):
            try:
                info = directory.lstat()
            except FileNotFoundError:
                if must_exist:
                    raise ValueError("diagnostic directory unavailable")
                continue
            if not stat.S_ISDIR(info.st_mode):
                raise ValueError("diagnostic directory is not a directory")
            with os.scandir(directory) as entries:
                for entry in entries:
                    scanned += 1
                    if scanned > MAX_DIAGNOSTIC_ENTRIES or time.monotonic() > deadline:
                        raise ValueError("diagnostic scan exceeded budget")
                    if not (entry.name.startswith(("WindowServer-", "WindowServer_"))
                            and entry.name.endswith((".ips", ".spin", ".crash", ".diag", ".hang"))):
                        continue
                    info = entry.stat(follow_symlinks=False)
                    if not stat.S_ISREG(info.st_mode) or not math.isfinite(info.st_mtime):
                        raise ValueError("diagnostic metadata unavailable")
                    if info.st_mtime >= since:
                        count += 1
    if time.monotonic() > deadline:
        raise ValueError("diagnostic scan exceeded budget")
    return count


def snapshot():
    until = time.monotonic() + SNAPSHOT_BUDGET
    pressure = read_command(["/usr/sbin/sysctl", "-n", "kern.memorystatus_vm_pressure_level"], until).strip()
    if pressure not in ("1", "2", "4"):
        raise ValueError("memory pressure unavailable")
    vm = read_command(["/usr/bin/vm_stat"], until)
    counters = {}
    for name in ("Swapins", "Swapouts"):
        values = re.findall(r"^" + name + r":\s+(\d+)\.\s*$", vm, re.MULTILINE)
        if len(values) != 1:
            raise ValueError("swap counters unavailable")
        counters[name] = int(values[0])
    services = service_sample(until)
    at = time.monotonic()
    if at > until:
        raise ValueError("snapshot exceeded budget")
    return dict(at=at, pressure=int(pressure), swap=counters, services=services)


def windowserver_timeouts(since, now):
    """Keep only a count; matching unified-log content never leaves this helper."""
    if not all(math.isfinite(value) for value in (since, now)) or not now-86400 <= since <= now:
        raise ValueError("invalid system-health evidence interval")
    predicate = ('(process == "WindowServer" OR process == "colorsync.displayservices" '
                 'OR process == "colorsyncd") AND '
                 '(eventMessage CONTAINS[c] "timed out" OR eventMessage CONTAINS[c] "timeout")')
    stamp = lambda value: datetime.fromtimestamp(value, timezone.utc).strftime('%Y-%m-%d %H:%M:%S')
    rows = json.loads(read_command(["/usr/bin/log", "show", "--style", "json", "--info", "--debug",
                                   "--timezone", "UTC", "--start", stamp(since), "--end", stamp(now),
                                   "--predicate", predicate]))
    if not isinstance(rows, list) or any(not isinstance(row, dict) or
            not isinstance(row.get("eventMessage"), str) for row in rows):
        raise ValueError("system-health log evidence unavailable")
    return len(rows)


def assess(before, after, diagnostic_reports=0):
    elapsed = after["at"] - before["at"]
    if not math.isfinite(elapsed) or not 4 <= elapsed <= 10:
        raise ValueError("insufficient sampling interval")
    if set(before["services"]) != set(SERVICES) or set(after["services"]) != set(SERVICES):
        raise ValueError("service changed during sampling")
    cpu = 0
    for service in SERVICES:
        old_pid, old, old_runs = before["services"][service]
        pid, new, runs = after["services"][service]
        if old_pid is None and pid is None:
            # No launch between the launchd reads, so no service CPU in the interval.
            if runs != old_runs:
                raise ValueError("service launched during sampling")
            continue
        if pid is None or pid <= 0 or not math.isfinite(new) or new < 0:
            raise ValueError("service changed during sampling")
        if old_pid is None:
            # Exactly one launch: its whole CPU bounds all work since the idle read.
            if runs != old_runs + 1:
                raise ValueError("service launched during sampling")
            cpu += new / elapsed * 100
            continue
        if pid != old_pid or runs != old_runs or new < old or not math.isfinite(new-old):
            raise ValueError("service changed during sampling")
        cpu += (new-old) / elapsed * 100
    swap = {key: after["swap"][key]-before["swap"][key] for key in ("Swapins", "Swapouts")}
    if any(value < 0 for value in swap.values()):
        raise ValueError("swap counters moved backwards")
    reasons = []
    if before["pressure"] != 1 or after["pressure"] != 1:
        reasons.append("memory_pressure")
    # Conservative test-admission policy, not a diagnosis or a macOS health threshold.
    if cpu >= 50:
        reasons.append("colorsync_busy")
    if any(swap.values()):
        reasons.append("swap_activity")
    if diagnostic_reports:
        reasons.append("recent_windowserver_diagnostic")
    return dict(schemaVersion=1, admitted=not reasons, reasons=reasons,
                intervalSeconds=round(elapsed, 3), colorsyncCPUPercent=round(cpu, 2),
                memoryPressureBefore=before["pressure"], memoryPressureAfter=after["pressure"],
                swapinsDelta=swap["Swapins"], swapoutsDelta=swap["Swapouts"],
                windowServerDiagnosticReports=diagnostic_reports)


def main():
    try:
        if sys.platform != "darwin":
            raise ValueError("requires macOS")
        if len(sys.argv) == 1:
            since = time.time() - 300
        elif len(sys.argv) == 3 and sys.argv[1] == "--since":
            since = float(sys.argv[2])
        else:
            raise ValueError("expected optional --since epoch-seconds")
        cutoff = diagnostic_cutoff(read_command(["/usr/sbin/sysctl", "-n", "kern.boottime"]), time.time())
        roots = [(Path("/Library/Logs/DiagnosticReports"), True),
                 (Path.home() / "Library/Logs/DiagnosticReports", False)]
        reports = windowserver_diagnostics(roots, cutoff)
        before = snapshot()
        time.sleep(5)
        after = snapshot()
        reports = max(reports, windowserver_diagnostics(roots, cutoff))
        report = assess(before, after, reports)
        report["systemServiceTimeouts"] = windowserver_timeouts(since, time.time())
        if report["systemServiceTimeouts"]:
            report["reasons"].append("system_service_timeout")
            report["admitted"] = False
    except (OSError, ValueError, subprocess.SubprocessError):
        # Do not print command output, process identities, or arbitrary exception content.
        print(json.dumps(dict(schemaVersion=1, admitted=False, reasons=["host_health_unknown"])))
        return 2
    print(json.dumps(report))
    return 0 if report["admitted"] else 1


if __name__ == "__main__":
    sys.exit(main())
