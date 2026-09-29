#!/usr/bin/env python3
"""Bounded candidate-daemon load, capture/Viewer and retained-memory workload.
Run through live-test-supervisor.py on a reserved host. Only generated sessions are mutated.
Reports contain timings/counts, never leases, screenshots, AX content or request payloads.
"""
import concurrent.futures
from contextlib import contextmanager
import json
import importlib.util
import hashlib
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]
MAX_REPLY = 8 * 1024 * 1024


def safety_stop():
    # Logging must never be a prerequisite for retaining a display owner.
    try:
        os.write(2, b"LIVE SAFETY STOP REQUEST: performance cleanup unconfirmed; inspect retained owner\n")
    finally:
        os.kill(os.getpid(), signal.SIGSTOP)
        while True:
            signal.pause()


@contextmanager
def retain_on_cleanup_failure(verified):
    try:
        yield
    except BaseException:
        if not verified():
            safety_stop()
        raise


def sampler_completed_early(child, target, label, path, elapsed):
    status = child.poll()
    if status is None:
        return False
    # The bounded probe exits normally by itself. Its sampler can observe that exit before
    # cleanup. Require recent coverage as well as a successful target exit; other early exits
    # (including sampler completion while a long-lived target remains alive) are failures.
    if status == 1 and label == "probe" and target.poll() == 0:
        with path.open("rb") as source:
            data = source.read(1024 * 1024 + 1)
        if len(data) <= 1024 * 1024:
            rows = data.splitlines()
            if len(rows) >= 2 and 0 <= elapsed - json.loads(rows[-1])["elapsedSeconds"] <= 2.5:
                return False
    return True


def executable_digest(path):
    digest = hashlib.sha256()
    remaining = 128 * 1024 * 1024
    with path.open("rb") as source:
        while True:
            chunk = source.read(min(1024 * 1024, remaining + 1))
            if len(chunk) > remaining:
                raise ValueError("executable exceeds profiling byte budget")
            if not chunk:
                return digest.hexdigest()
            digest.update(chunk)
            remaining -= len(chunk)


def request(path, cmd, **fields):
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(65)
        client.connect(path)
        client.sendall(json.dumps(dict(cmd=cmd, **fields)).encode() + b"\n")
        data = bytearray()
        while b"\n" not in data:
            part = client.recv(min(65536, MAX_REPLY + 1 - len(data)))
            if not part:
                raise RuntimeError("daemon disconnected before complete reply")
            data.extend(part)
            if len(data) > MAX_REPLY:
                raise RuntimeError("daemon reply exceeded byte budget")
        result = json.loads(data.split(b"\n", 1)[0])
        if not result.get("ok"):
            # Error codes are safe; arbitrary daemon error text may contain user content.
            raise RuntimeError("daemon refused " + cmd + ": " + str(result.get("errorCode", "unknown")))
        return result


def fixture_markup(path):
    mode = path.split("?")[-1]
    if mode not in ("static", "animated", "scrolling"):
        mode = "static"
    markup = f'''<!doctype html><title>SpaceO performance {mode}</title>
<style>body{{margin:0;background:#111927;color:white;font:24px system-ui}}section{{height:100px;padding:10px;border-bottom:1px solid #46556a}}
#box{{position:fixed;top:80px;left:80px;width:180px;height:180px;background:#25bdab;box-shadow:0 6px 20px #0007}}
@keyframes travel{{to{{transform:translate(650px,340px) rotate(180deg)}}}}</style>
<h1>SpaceO synthetic performance fixture</h1><div id=box></div>
<script>const mode={json.dumps(mode)};for(let i=0;i<100;i++){{const s=document.createElement('section');s.textContent='Synthetic row '+i;document.body.append(s)}}
if(mode==='animated')box.style.animation='travel 2s linear infinite alternate';
if(mode==='scrolling'){{let t=0;function step(){{t+=8;scrollTo(0,t%6000);requestAnimationFrame(step)}}requestAnimationFrame(step)}}
let frames=0;function tick(){{frames++;requestAnimationFrame(tick)}}requestAnimationFrame(tick);
setInterval(()=>navigator.sendBeacon('/fixture-health',JSON.stringify({{mode,visibility:document.visibilityState,frames}})),1000);
</script>'''.encode()
    return markup


def main():
    if os.environ.get("SPACEO_LIVE_TESTS") != "1":
        raise SystemExit("requires SPACEO_LIVE_TESTS=1 on a reserved host")
    if len(sys.argv) != 2:
        raise SystemExit("usage: performance-live.py PRIVATE_REPORT_DIRECTORY")
    os.umask(0o077)
    out = Path(sys.argv[1]).resolve()
    out.mkdir(mode=0o700, parents=True, exist_ok=False)
    binary = ROOT / ".build/release/spaceo"
    viewer_binary = Path(os.environ.get("SPACEO_PERF_VIEWER_BINARY",
        str(ROOT / ".build/SpaceO Viewer.app/Contents/MacOS/SpaceOViewer"))).resolve()
    sampler = ROOT / ".build/process-resources"
    if not all(p.is_file() for p in (binary, viewer_binary, sampler)):
        raise SystemExit("build the CLI, Viewer bundle and process-resources sampler first")
    if os.environ.get("SPACEO_PERF_NATIVE_PROBE") == "1" and not (ROOT / ".build/performance-metal-probe").is_file():
        raise SystemExit("compile Tests/LiveFixtures/TranscriptProbe.swift as .build/performance-metal-probe first")
    scratch = tempfile.TemporaryDirectory(prefix="spaceo-perf-live-")
    sock = str(Path(scratch.name) / "daemon.sock")
    environment = dict(os.environ, SPACEO_SOCKET=sock, SPACEO_LOG_FILE=str(out / "daemon.log"),
                       SPACEO_JOURNAL="off", SPACEO_LOG_METRICS="1")
    daemon_only = os.environ.get("SPACEO_PERF_DAEMON_ONLY") == "1"
    native_probe = os.environ.get("SPACEO_PERF_NATIVE_PROBE") == "1"
    if daemon_only and native_probe:
        raise SystemExit("choose either daemon-only or native-probe workload")
    viewer_only = native_probe or os.environ.get("SPACEO_PERF_VIEWER_ONLY") == "1"
    started = time.monotonic()
    phases, operations, owned, subscribers, samplers = [], [], {}, [], []
    sample_starts = {}
    fixture_records = []
    fixture_lock = threading.Lock()
    daemon = viewer = server = probe = None
    handles = []
    baseline = None
    success = False
    topology_restored = False

    def progress(name):
        record = dict(phase=name, elapsedSeconds=time.monotonic() - started)
        phases.append(record)
        (out / "phases.json").write_text(json.dumps(phases, indent=2))
        print("performance phase: " + name, flush=True)

    def pause(seconds):
        if time.monotonic() - started + seconds > 600:
            raise RuntimeError("performance run deadline exceeded")
        time.sleep(seconds)

    def call(cmd, **fields):
        began = time.monotonic()
        result = request(sock, cmd, diagnosticClient="performance", **fields)
        operations.append(dict(command=cmd, ms=(time.monotonic()-began)*1000))
        return result

    def sample(process, label):
        sample_starts[label] = time.monotonic() - started
        (out / "sample-starts.json").write_text(json.dumps(sample_starts))
        handle = (out / (label + "-resources.jsonl")).open("wb")
        errors = (out / (label + "-sampler.log")).open("wb")
        handles.extend((handle, errors))
        child = subprocess.Popen([sampler, str(process.pid), "600", "1"], stdout=handle, stderr=errors)
        samplers.append((child, process, label))

    def doctor():
        result = subprocess.run([binary, "doctor", "--json"], env=environment,
                                capture_output=True, timeout=15)
        return json.loads(result.stdout)

    def topology(report):
        return {k: report["displays"][k] for k in
                ("userActive", "userOnline", "mirroredUser", "spaceO", "orphanedSpaceO")}

    class Fixture(BaseHTTPRequestHandler):
        def do_POST(self):
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 256:
                    raise ValueError("invalid fixture report length")
                self.connection.settimeout(2)
                value = json.loads(self.rfile.read(length))
                mode, visibility, frames = value["mode"], value["visibility"], value["frames"]
                if mode not in ("static", "animated", "scrolling") or visibility not in ("visible", "hidden"):
                    raise ValueError("invalid fixture state")
                if type(frames) is not int or not 0 <= frames <= 1_000_000:
                    raise ValueError("invalid frame count")
                with fixture_lock:
                    if len(fixture_records) < 600:
                        fixture_records.append(dict(elapsedSeconds=time.monotonic()-started,
                                                    mode=mode, visibility=visibility, frames=frames))
                self.send_response(204)
            except (ValueError, KeyError, OSError, TypeError):
                self.send_response(400)
            self.end_headers()

        def do_GET(self):
            markup = fixture_markup(self.path)
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(markup)))
            self.end_headers()
            self.wfile.write(markup)
        def log_message(self, *_):
            pass

    try:
        progress("preflight")
        baseline = doctor()
        if not baseline.get("canDrive") or not baseline.get("canCapture"):
            raise RuntimeError("host input/capture prerequisites unavailable")
        if baseline.get("displaySafety", {}).get("state") != "ready":
            raise RuntimeError("display safety not ready")
        if baseline["displays"]["spaceO"] or baseline["displays"]["orphanedSpaceO"]:
            raise RuntimeError("existing virtual displays; refusing to alter unrelated state")
        log = (out / "daemon-console.log").open("wb"); handles.append(log)
        daemon = subprocess.Popen([binary, "daemon", "--sessions-per-display", "4", "--display-size", "2560x1440"],
                                  env=environment, stdout=log, stderr=subprocess.STDOUT)
        for _ in range(100):
            if daemon.poll() is not None:
                raise RuntimeError("candidate daemon exited during startup")
            try:
                ping = request(sock, "ping")
                break
            except (OSError, RuntimeError):
                pause(.1)
        else:
            raise RuntimeError("candidate daemon startup deadline exceeded")
        health = doctor()
        if health.get("daemon", {}).get("matchesCLI") is not True:
            raise RuntimeError("candidate daemon does not match CLI")
        (out / "provenance.json").write_text(json.dumps(dict(
            buildUUID=ping["daemon"]["executableBuildUUID"],
            viewerSHA256=executable_digest(viewer_binary),
            sha256=ping["daemon"]["executableSHA256"], version=ping["daemon"]["version"]), indent=2))
        sample(daemon, "daemon")
        progress("idle-daemon"); pause(10)
        for concurrency in (() if viewer_only else (1, 4, 8)):
            progress("read-load-" + str(concurrency))
            def read_batch(_):
                for i in range(60):
                    call(("ping", "session.list", "pool")[i % 3])
            with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as workers:
                list(workers.map(read_batch, range(concurrency)))
        progress("sessions-and-subscribers")
        for index in range(4 if daemon_only else 1):
            name = "perf-" + str(index)
            response = call("session.create", session=name,
                            controllerOwner=dict(id="performance-fixture", kind="cli", label="Performance fixture"),
                            controllerTTLSeconds=600)
            owned[name] = response["controllerLeaseID"]
        for _ in range(0 if viewer_only else 16):
            channel = socket.socket(socket.AF_UNIX); channel.settimeout(1); channel.connect(sock)
            channel.sendall(b'{"cmd":"events.subscribe","operatorScope":true}\n')
            subscribers.append(channel)
            hello = bytearray()
            while b"\n" not in hello:
                part = channel.recv(min(4096, 65537-len(hello)))
                if not part or len(hello) + len(part) > 65536:
                    raise RuntimeError("subscriber handshake incomplete or oversized")
                hello.extend(part)
            if not json.loads(hello.split(b"\n", 1)[0]).get("ok"):
                raise RuntimeError("subscriber admission refused")
            def drain(channel=channel):
                while True:
                    try:
                        if not channel.recv(65536): return
                    except socket.timeout: continue
                    except OSError: return
            threading.Thread(target=drain, daemon=True).start()
        server = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        if not native_probe:
            call("run", session="perf-0", controllerLeaseID=owned["perf-0"], app="Google Chrome",
                 timeout=30)
        if not daemon_only:
            viewer_log = (out / "viewer-console.log").open("wb"); handles.append(viewer_log)
            viewer = subprocess.Popen([viewer_binary, "--background"],
                                      env=dict(environment, SPACEO_VIEWER_METRICS_FILE=str(out / "viewer-health.jsonl")),
                                      stdout=viewer_log, stderr=subprocess.STDOUT)
            (out / "processes.json").write_text(json.dumps(dict(daemon=daemon.pid, viewer=viewer.pid)))
            sample(viewer, "viewer")
            if native_probe:
                entries = call("session.list")["sessions"]
                display_id = next(entry["displayID"] for entry in entries if entry["id"] == "perf-0")
                probe_log = (out / "native-probe.json").open("wb"); handles.append(probe_log)
                probe_errors = (out / "native-probe.log").open("wb"); handles.append(probe_errors)
                progress("viewer-native")
                probe = subprocess.Popen([ROOT / ".build/performance-metal-probe", "--display-id",
                    str(display_id), "--duration", "15", "--mode", "normal"],
                    env=dict(environment, SPACEO_TRANSCRIPT_PROBE_LIVE="1", SPACEO_PERF_PROBE_READY="1"),
                    stdout=probe_log, stderr=probe_errors)
                sample(probe, "probe")
                for _ in range(50):
                    if probe.poll() is not None:
                        raise RuntimeError("native probe exited before readiness")
                    if (out / "native-probe.json").stat().st_size > 0:
                        break
                    pause(.1)
                else:
                    raise RuntimeError("native probe readiness deadline exceeded")
                call("adopt", session="perf-0", controllerLeaseID=owned["perf-0"],
                     pid=probe.pid, allowNoWindows=False)
                for _ in range(20):
                    entry = next(item for item in call("session.list", controllerLeaseID=owned["perf-0"])["sessions"] if item["id"] == "perf-0")
                    if any(window["pid"] == probe.pid and window["onStage"] for window in entry["windows"]):
                        break
                    pause(.25)
                else:
                    raise RuntimeError("native probe placement was not verified")
                digests = []
                for _ in range(2):
                    capture = call("screenshot", session="perf-0", controllerLeaseID=owned["perf-0"], memory=True)
                    if not capture.get("imageBase64"):
                        raise RuntimeError("native probe capture missing")
                    digests.append(hashlib.sha256(capture["imageBase64"].encode()).digest())
                    del capture
                    pause(.3)
                (out / "native-capture.json").write_text(json.dumps(dict(changingPixels=digests[0] != digests[1])))
                if digests[0] == digests[1]:
                    raise RuntimeError("native probe captures did not change")
                pause(12)
                if probe.wait(timeout=10) != 0:
                    raise RuntimeError("native probe failed")
                health_rows = [json.loads(line) for line in (out / "viewer-health.jsonl").read_text().splitlines()[-5:]]
                delivered = any(row.get("windowsOnPhysicalDisplay", 0) > 0
                           and row.get("windowsOnSpaceODisplay", 0) == 0
                           and (row.get("framesPerSecond") or 0) > 1 for row in health_rows)
                evidence = json.loads((out / "native-probe.json").read_text().splitlines()[-1])
                if evidence["gpuFailures"] != 0 or evidence["gpuCompletions"] < 2:
                    raise RuntimeError("native probe did not confirm completed GPU work")
                if not delivered:
                    raise RuntimeError("native probe did not demonstrate Viewer frame delivery")
                success = True
                return
            for mode in ("static", "animated", "scrolling"):
                call("open.url", session="perf-0", controllerLeaseID=owned["perf-0"],
                     url="http://127.0.0.1:" + str(server.server_port) + "/?" + mode)
                call("wait", session="perf-0", controllerLeaseID=owned["perf-0"],
                     waitCondition="web_title_contains", waitValue="SpaceO performance " + mode, timeout=10)
                progress("viewer-" + mode); pause(20)
                if mode == "static":
                    latest_health = json.loads((out / "viewer-health.jsonl").read_text().splitlines()[-1])
                    if latest_health.get("windowsOnPhysicalDisplay", 0) < 1 or latest_health.get("windowsOnSpaceODisplay", 0) > 0:
                        raise RuntimeError("Viewer physical-display placement not verified")
                    # Preserve the Viewer's initial selection of the only attached session.
                    for index in range(1, 1 if viewer_only else 4):
                        name = "perf-" + str(index)
                        response = call("session.create", session=name,
                                        controllerOwner=dict(id="performance-fixture", kind="cli", label="Performance fixture"),
                                        controllerTTLSeconds=600)
                        owned[name] = response["controllerLeaseID"]
                else:
                    health_rows = [json.loads(line) for line in (out / "viewer-health.jsonl").read_text().splitlines()[-10:]]
                    digests = []
                    for _ in range(2):
                        capture = call("screenshot", session="perf-0", controllerLeaseID=owned["perf-0"], memory=True)
                        if not capture.get("imageBase64"):
                            raise RuntimeError("browser diagnostic capture missing")
                        digests.append(hashlib.sha256(capture["imageBase64"].encode()).digest())
                        del capture
                        pause(1.3)
                    (out / (mode + "-capture.json")).write_text(json.dumps(dict(changingPixels=digests[0] != digests[1])))
                    if digests[0] == digests[1]:
                        raise RuntimeError("browser diagnostic captures did not change")
                    if not any(row.get("streamRunning") and row.get("frameSinks", 0) > 0
                               and row.get("unoccludedWindows", 0) > 0
                               and (row.get("framesPerSecond") or 0) > 1 for row in health_rows):
                        raise RuntimeError("Viewer did not demonstrate active rendering")
            if viewer_only:
                success = True
                return
        else:
            call("open.url", session="perf-0", controllerLeaseID=owned["perf-0"],
                 url="http://127.0.0.1:" + str(server.server_port) + "/?static")
            call("wait", session="perf-0", controllerLeaseID=owned["perf-0"],
                 waitCondition="web_title_contains", waitValue="SpaceO performance static", timeout=10)
        progress("capture-scales")
        for scale in (1, 2):
            for _ in range(20):
                result = call("screenshot", session="perf-0", controllerLeaseID=owned["perf-0"], memory=True, scale=scale)
                if not result.get("imageBase64") or result.get("capture", {}).get("persistence") != "memory":
                    raise RuntimeError("capture did not produce bounded in-memory evidence")
                del result
        progress("logical-session-churn")
        for index in range(3):
            name = "perf-" + str(index+1)
            call("session.destroy", session=name, controllerLeaseID=owned[name]); del owned[name]
        # The anchor holds the one display. These iterations reuse tiles, not display identities.
        for index in range(30):
            name = "perf-churn"
            response = call("session.create", session=name, controllerOwner=dict(id="performance-fixture", kind="cli", label="Performance fixture"))
            owned[name] = response["controllerLeaseID"]
            call("session.destroy", session=name, controllerLeaseID=owned[name]); del owned[name]
        progress("capture-soak")
        call("open.url", session="perf-0", controllerLeaseID=owned["perf-0"],
             url="http://127.0.0.1:" + str(server.server_port) + "/?static")
        for _ in range(360):
            result = call("screenshot", session="perf-0", controllerLeaseID=owned["perf-0"], memory=True)
            if not result.get("imageBase64"): raise RuntimeError("capture lost pixels")
            del result
            pause(.5)
        progress("idle-after-capture"); pause(20)
        success = True
    finally:
        with retain_on_cleanup_failure(lambda: daemon is None or
                (topology_restored and daemon.poll() is not None)):
            sampler_errors = []
            for child, target, label in samplers:
                if sampler_completed_early(child, target, label, out / (label + "-resources.jsonl"),
                                           time.monotonic() - started - sample_starts[label]):
                    sampler_errors.append(label + " resource sampler exited before completion")
            if sampler_errors:
                success = False
            # Check and stop these samplers while their targets still exist; the daemon
            # remains sampled through the post-teardown idle phase below.
            for child, _, label in samplers:
                if label != "daemon" and child.poll() is None:
                    child.terminate()
                    child.wait(timeout=5)
            progress("cleanup")
            cleanup_errors = []
            if probe is not None and probe.poll() is None:
                try: probe.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    probe.terminate()
                    try: probe.wait(timeout=10)
                    except subprocess.TimeoutExpired: cleanup_errors.append("native probe did not exit")
            if viewer is not None and viewer.poll() is None:
                viewer.terminate()
                try: viewer.wait(timeout=10)
                except subprocess.TimeoutExpired: cleanup_errors.append("Viewer did not exit")
            for channel in subscribers: channel.close()
            for name, lease in list(owned.items()):
                try:
                    call("session.destroy", session=name, controllerLeaseID=lease)
                    del owned[name]
                except Exception:
                    cleanup_errors.append("session cleanup unconfirmed")
            if server is not None: server.shutdown(); server.server_close()
            with fixture_lock:
                (out / "fixture-health.json").write_text(json.dumps(fixture_records, indent=2))
            try:
                if daemon is not None and daemon.poll() is None and not cleanup_errors:
                    for _ in range(25):
                        if call("pool").get("usage", {}).get("displays") == 0: break
                        time.sleep(1)
                    else: cleanup_errors.append("display retirement unconfirmed")
                    if not cleanup_errors:
                        progress("idle-after-teardown"); time.sleep(15)
                        for child, target, label in samplers:
                            if label == "daemon":
                                if sampler_completed_early(child, target, label,
                                        out / (label + "-resources.jsonl"),
                                        time.monotonic() - started - sample_starts[label]):
                                    sampler_errors.append("daemon resource sampler exited before completion")
                                    success = False
                                if child.poll() is None:
                                    child.terminate()
                                    child.wait(timeout=5)
                        call("daemon.stop", operatorScope=True)
                        try: daemon.wait(timeout=15)
                        except subprocess.TimeoutExpired: cleanup_errors.append("daemon stop unconfirmed")
            except Exception:
                cleanup_errors.append("daemon cleanup could not be verified")
            if cleanup_errors:
                (out / "operations.json").write_text(json.dumps(operations, indent=2))
                (out / "summary.json").write_text(json.dumps(dict(ok=False, topologyRestored=False,
                    cleanupErrors=cleanup_errors, operations=len(operations), phases=phases,
                    elapsedSeconds=time.monotonic()-started), indent=2))
                safety_stop()
            for child, _, _ in samplers:
                if child.poll() is None: child.terminate()
                child.wait(timeout=5)
            for handle in handles: handle.close()
            if baseline is not None:
                after = doctor()
                if topology(after) != topology(baseline) or after.get("displaySafety", {}).get("state") != "ready":
                    success = False
                    raise RuntimeError("postflight topology or display safety changed")
                topology_restored = True
            scratch.cleanup()
            (out / "operations.json").write_text(json.dumps(operations, indent=2))
            (out / "summary.json").write_text(json.dumps(dict(ok=success, topologyRestored=topology_restored,
                samplerErrors=sampler_errors, operations=len(operations), phases=phases,
                elapsedSeconds=time.monotonic()-started), indent=2))
            if sampler_errors:
                raise RuntimeError("resource sampling failed; see private summary")
    print("performance live workload passed", flush=True)

if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--supervised-worker":
        del sys.argv[1]
        main()
    else:
        if len(sys.argv) != 2 or os.environ.get("SPACEO_LIVE_TESTS") != "1":
            raise SystemExit("usage: SPACEO_LIVE_TESTS=1 performance-live.py NEW_PRIVATE_REPORT_DIRECTORY")
        spec = importlib.util.spec_from_file_location("live_supervisor", ROOT / "scripts/live-test-supervisor.py")
        supervisor = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(supervisor)
        report = str(Path(sys.argv[1]).resolve())
        raise SystemExit(supervisor.supervise(
            [sys.executable, str(Path(__file__).resolve()), "--supervised-worker", report],
            report + "-supervisor.log", run_timeout=650))
