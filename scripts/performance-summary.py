#!/usr/bin/env python3
"""Summarize bounded performance-live.py reports; no raw daemon logs or image content."""
import json
import math
import os
from pathlib import Path
import stat
import statistics
import sys


def read(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise ValueError("report must be a regular file")
        with os.fdopen(descriptor, "rb", closefd=False) as source:
            data = source.read(16 * 1024 * 1024 + 1)
    finally:
        os.close(descriptor)
    if len(data) > 16 * 1024 * 1024:
        raise ValueError("report exceeds 16 MiB")
    return data.decode("utf-8")


def summarize(root):
    summary = json.loads(read(root / "summary.json"))
    viewer_modes = summary.get("requestedViewerModes")
    if viewer_modes is not None and viewer_modes not in (
            [], ["static", "animated"], ["static", "scrolling"],
            ["static", "animated", "scrolling"]):
        raise ValueError("invalid requested Viewer modes")
    phases = summary["phases"]
    offsets = json.loads(read(root / "sample-starts.json"))
    resources = {}
    for role, offset in offsets.items():
        if role not in ("daemon", "viewer", "probe"):
            raise ValueError("unknown resource role")
        rows = [json.loads(line) for line in read(root / (role + "-resources.jsonl")).splitlines()]
        if len(rows) < 2:
            raise ValueError("insufficient process samples")
        role_phases = {}
        for index, phase in enumerate(phases):
            end = phases[index + 1]["elapsedSeconds"] if index+1 < len(phases) else summary["elapsedSeconds"]
            # Leave one sample interval at both boundaries to avoid mixing phase transitions.
            selected = [r for r in rows if phase["elapsedSeconds"] + 1 <= r["elapsedSeconds"]+offset < end-1]
            if len(selected) < 2:
                continue
            a, b = selected[0], selected[-1]
            seconds = b["elapsedSeconds"]-a["elapsedSeconds"]
            cpu = sum(b["sample"][k]-a["sample"][k] for k in ("cpuUserSeconds", "cpuSystemSeconds"))
            if seconds <= 0 or cpu < 0:
                raise ValueError("nonmonotonic process counters")
            memory = [r["sample"]["physicalFootprintBytes"]/1048576 for r in selected]
            role_phases[phase["phase"]] = dict(samples=len(selected), cpuPercent=round(cpu/seconds*100,3),
                footprintStartMiB=round(memory[0],3), footprintEndMiB=round(memory[-1],3),
                footprintPeakMiB=round(max(memory),3),
                interruptWakeupsPerSecond=round((b["sample"]["interruptWakeups"]-a["sample"]["interruptWakeups"])/seconds,3))
        resources[role] = role_phases
    operations = json.loads(read(root / "operations.json"))
    latencies = {}
    for command in sorted({r["command"] for r in operations}):
        values = sorted(r["ms"] for r in operations if r["command"] == command)
        latencies[command] = dict(count=len(values), p50Ms=round(statistics.median(values),3),
            p95Ms=round(values[max(0, math.ceil(len(values)*.95)-1)],3),
            p99Ms=round(values[max(0, math.ceil(len(values)*.99)-1)],3))
    result = dict(ok=summary["ok"], topologyRestored=summary["topologyRestored"],
                  requestedViewerModes=viewer_modes,
                  elapsedSeconds=summary["elapsedSeconds"], resources=resources, latencies=latencies)
    health = root / "viewer-health.jsonl"
    if health.exists():
        rows = [json.loads(line) for line in read(health).splitlines()]
        result["viewerEvidence"] = dict(samples=len(rows), liveSamples=sum(r["streamRunning"] for r in rows),
            unoccludedSamples=sum(r["unoccludedWindows"] > 0 for r in rows),
            frameSinkSamples=sum(r["frameSinks"] > 0 for r in rows),
            maxFPS=max((r.get("framesPerSecond",0) or 0 for r in rows), default=0),
            screenRecordingGranted=bool(rows) and all(r["screenRecordingGranted"] for r in rows))
    fixture = root / "fixture-health.json"
    if fixture.exists():
        rows = json.loads(read(fixture))
        evidence = {}
        for mode in ("static", "animated", "scrolling"):
            selected = [r for r in rows if r["mode"] == mode]
            evidence[mode] = dict(samples=len(selected),
                visibleSamples=sum(r["visibility"] == "visible" for r in selected),
                hiddenSamples=sum(r["visibility"] == "hidden" for r in selected),
                minFrames=min((r["frames"] for r in selected), default=None),
                maxFrames=max((r["frames"] for r in selected), default=None))
        result["fixtureEvidence"] = evidence
    return result


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: performance-summary.py REPORT_DIRECTORY")
    print(json.dumps(summarize(Path(sys.argv[1])), indent=2, allow_nan=False))
