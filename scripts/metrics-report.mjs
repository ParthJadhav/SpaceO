#!/usr/bin/env node

// Summarize SpaceO's bounded NDJSON daemon log without retaining request payloads.
// usage: node scripts/metrics-report.mjs LOG [LOG.1 ...] [--run=RUN_ID] [--json]

import { existsSync, readFileSync, statSync } from "node:fs";

const args = process.argv.slice(2);
const paths = args.filter((value) => !value.startsWith("--"));
const runID = (args.find((value) => value.startsWith("--run=")) ?? "").slice(6) || null;
const asJSON = args.includes("--json");
const maximumLogBytes = 20 * 1_048_576;
const maximumTotalLogBytes = 40 * 1_048_576;

if (!paths.length) {
  console.error("usage: node scripts/metrics-report.mjs LOG [LOG.1 ...] [--run=RUN_ID] [--json]");
  process.exit(2);
}

const events = [];
const sources = [];
const missingPaths = [];
let invalidLines = 0;
let totalBytes = 0;
for (const path of paths) {
  if (!existsSync(path)) {
    missingPaths.push(path);
    continue;
  }
  sources.push(path);
  const size = statSync(path).size;
  if (size > maximumLogBytes) {
    throw new Error(`${path} is ${size} bytes; refusing to read more than ${maximumLogBytes}`);
  }
  totalBytes += size;
  if (totalBytes > maximumTotalLogBytes) {
    throw new Error(`refusing to read more than ${maximumTotalLogBytes} bytes across log files`);
  }
  for (const line of readFileSync(path, "utf8").split("\n")) {
    if (!line.trim()) continue;
    try {
      const event = JSON.parse(line);
      if (!runID || event.run === runID) events.push(event);
    } catch {
      invalidLines += 1;
    }
  }
}

const requests = events.filter((event) =>
  event.kind === "request.ok" || event.kind === "request.failed");

function number(value) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function percentile(values, fraction) {
  const sorted = values.filter((value) => value !== null).sort((a, b) => a - b);
  if (!sorted.length) return null;
  return sorted[Math.max(0, Math.ceil(sorted.length * fraction) - 1)];
}

function summarize(group) {
  const latencies = group.map((event) => number(event.ms));
  const userCPU = group.map((event) => number(event.cpu_user_ms));
  const systemCPU = group.map((event) => number(event.cpu_system_ms));
  const rss = group.map((event) => number(event.rss_bytes)).filter((value) => value !== null);
  const footprint = group
    .map((event) => number(event.physical_footprint_bytes))
    .filter((value) => value !== null);
  return {
    count: group.length,
    failed: group.filter((event) => event.kind === "request.failed").length,
    warnings: group.reduce((sum, event) => sum + (number(event.warning_count) ?? 0), 0),
    truncated: group.filter((event) => event.truncated === "true").length,
    isolationBreaches: group.filter((event) => event.isolation_verdict === "breached").length,
    latencyMs: {
      p50: percentile(latencies, 0.50),
      p95: percentile(latencies, 0.95),
      p99: percentile(latencies, 0.99),
      max: percentile(latencies, 1),
    },
    cpuMs: {
      userP95: percentile(userCPU, 0.95),
      systemP95: percentile(systemCPU, 0.95),
    },
    memoryBytes: {
      rssFirst: rss.at(0) ?? null,
      rssLast: rss.at(-1) ?? null,
      rssGrowth: rss.length ? rss.at(-1) - rss[0] : null,
      rssMax: rss.length ? rss.reduce((maximum, value) => Math.max(maximum, value), 0) : null,
      physicalFootprintFirst: footprint.at(0) ?? null,
      physicalFootprintLast: footprint.at(-1) ?? null,
      physicalFootprintGrowth: footprint.length ? footprint.at(-1) - footprint[0] : null,
      physicalFootprintMax: footprint.length
        ? footprint.reduce((maximum, value) => Math.max(maximum, value), 0)
        : null,
    },
  };
}

const commands = {};
for (const command of [...new Set(requests.map((event) => event.cmd ?? "unknown"))].sort()) {
  commands[command] = summarize(requests.filter((event) => (event.cmd ?? "unknown") === command));
}
const lifecycle = {};
for (const event of events.filter((candidate) =>
  !String(candidate.kind ?? "unknown").startsWith("request."))) {
  const kind = String(event.kind ?? "unknown");
  lifecycle[kind] = (lifecycle[kind] ?? 0) + 1;
}

const report = {
  schemaVersion: 1,
  runID,
  sources,
  missingPaths,
  invalidLines,
  eventCount: events.length,
  requestCount: requests.length,
  summary: summarize(requests),
  commands,
  lifecycle,
};

if (asJSON) {
  console.log(JSON.stringify(report, null, 2));
} else {
  const overall = report.summary;
  console.log(`SpaceO metrics${runID ? ` for ${runID}` : ""}`);
  console.log(`  ${overall.count} requests; ${overall.failed} failed; `
    + `${overall.warnings} warnings; ${overall.isolationBreaches} isolation breaches`);
  console.log(`  latency ms p50=${overall.latencyMs.p50 ?? "n/a"} `
    + `p95=${overall.latencyMs.p95 ?? "n/a"} p99=${overall.latencyMs.p99 ?? "n/a"} `
    + `max=${overall.latencyMs.max ?? "n/a"}`);
  console.log(`  RSS max=${overall.memoryBytes.rssMax ?? "n/a"} `
    + `growth=${overall.memoryBytes.rssGrowth ?? "n/a"}; `
    + `footprint max=${overall.memoryBytes.physicalFootprintMax ?? "n/a"} `
    + `growth=${overall.memoryBytes.physicalFootprintGrowth ?? "n/a"}`);
  for (const [command, value] of Object.entries(commands)) {
    console.log(`  ${command}: n=${value.count} fail=${value.failed} `
      + `p50=${value.latencyMs.p50 ?? "n/a"} p95=${value.latencyMs.p95 ?? "n/a"} `
      + `p99=${value.latencyMs.p99 ?? "n/a"} max=${value.latencyMs.max ?? "n/a"}`);
  }
  if (invalidLines) console.log(`  warning: ${invalidLines} invalid NDJSON line(s)`);
  if (missingPaths.length) {
    console.log(`  note: skipped ${missingPaths.length} missing optional log file(s)`);
  }
}

if (!sources.length || !requests.length) process.exitCode = 2;
