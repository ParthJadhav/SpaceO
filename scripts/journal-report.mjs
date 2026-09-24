#!/usr/bin/env node

// Turn the MCP agent journal (and optionally the daemon log) into an improvement-loop report:
// where agents spend calls, tokens and time, which errors they hit, whether they follow the
// recovery hints, and which friction patterns recur — ranked, with example traces to open.
//
// usage: node scripts/journal-report.mjs [JOURNAL_DIR_OR_FILE ...] [--daemon-log FILE ...]
//                                        [--since=YYYY-MM-DD] [--top=N] [--json]
// default journal dir: ~/Library/Logs/SpaceO/journal
//
// Everything stays local. The report quotes error messages and first result lines, never typed
// text (the journal never contains it).

import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const maximumFileBytes = 64 * 1_048_576;
const maximumTotalBytes = 512 * 1_048_576;

export function parseArguments(argv) {
  const options = { inputs: [], daemonLogs: [], since: null, top: 10, json: false };
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === "--json") options.json = true;
    else if (value.startsWith("--since=")) options.since = value.slice(8);
    else if (value.startsWith("--top=")) options.top = Math.max(1, Math.min(100, Number(value.slice(6)) || 10));
    else if (value === "--daemon-log") options.daemonLogs.push(argv[++index]);
    else if (value.startsWith("--daemon-log=")) options.daemonLogs.push(value.slice(13));
    else if (value.startsWith("--")) throw new Error(`unknown option ${value}`);
    else options.inputs.push(value);
  }
  if (!options.inputs.length) options.inputs.push(join(homedir(), "Library/Logs/SpaceO/journal"));
  return options;
}

function listFiles(path, pattern) {
  if (!existsSync(path)) return [];
  if (statSync(path).isFile()) return [path];
  const found = [];
  for (const entry of readdirSync(path, { withFileTypes: true }).slice(0, 5_000)) {
    const child = join(path, entry.name);
    if (entry.isDirectory()) found.push(...listFiles(child, pattern));
    else if (pattern.test(entry.name)) found.push(child);
  }
  return found.sort();
}

function readJSONLines(files, budget) {
  const records = [];
  let invalid = 0;
  for (const file of files) {
    const size = statSync(file).size;
    if (size > maximumFileBytes) throw new Error(`${file} is ${size} bytes; refusing more than ${maximumFileBytes}`);
    budget.bytes += size;
    if (budget.bytes > maximumTotalBytes) throw new Error(`refusing to read more than ${maximumTotalBytes} bytes`);
    for (const line of readFileSync(file, "utf8").split("\n")) {
      if (!line.trim()) continue;
      try { records.push(JSON.parse(line)); } catch { invalid += 1; }
    }
  }
  return { records, invalid };
}

const percentile = (values, fraction) => {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor(fraction * sorted.length))];
};
const increment = (map, key, by = 1) => map.set(key, (map.get(key) ?? 0) + by);
const actionTools = new Set(["spaceo_click", "spaceo_type", "spaceo_press_key", "spaceo_scroll",
  "spaceo_move", "spaceo_drag", "spaceo_select_text", "spaceo_menu"]);
const readTools = new Set(["spaceo_read_screen", "spaceo_screenshot", "spaceo_find", "spaceo_read_text"]);

export function analyze(journalRecords, daemonRecords = [], { since = null, top = 10 } = {}) {
  const inRange = (record) => !since || (record.ts ?? "") >= since;
  const calls = journalRecords.filter((record) => record.kind === "tool_call" && inRange(record));
  const connections = new Map();
  for (const record of journalRecords.filter(inRange)) {
    const connection = connections.get(record.conn) ?? { calls: 0, client: null, ended: null, sessions: new Set(), destroyed: new Set() };
    if (record.client?.name) connection.client = `${record.client.name} ${record.client.version ?? ""}`.trim();
    if (record.kind === "connection.end") connection.ended = record.reason;
    if (record.kind === "tool_call") {
      connection.calls += 1;
      if (record.session) connection.sessions.add(record.session);
      if (record.tool === "spaceo_session_destroy" && record.outcome !== "tool_error" && record.session) connection.destroyed.add(record.session);
    }
    connections.set(record.conn, connection);
  }

  // Per tool.
  const byTool = new Map();
  for (const call of calls) {
    const tool = byTool.get(call.tool) ?? { calls: 0, errors: 0, ms: [], tokens: 0 };
    tool.calls += 1;
    if (call.error) tool.errors += 1;
    tool.ms.push(call.ms ?? 0);
    tool.tokens += call.result?.est_tokens ?? 0;
    byTool.set(call.tool, tool);
  }
  const tools = [...byTool.entries()].map(([name, tool]) => ({
    tool: name, calls: tool.calls, errors: tool.errors,
    error_rate: tool.calls ? tool.errors / tool.calls : 0,
    p50_ms: percentile(tool.ms, 0.5), p95_ms: percentile(tool.ms, 0.95),
    tokens: tool.tokens, avg_tokens: tool.calls ? Math.round(tool.tokens / tool.calls) : 0,
  })).sort((a, b) => b.calls - a.calls);

  // Errors and whether the recovery hint was followed by the very next call.
  const errors = new Map();
  const ordered = [...calls].sort((a, b) => (a.conn === b.conn ? (a.seq ?? 0) - (b.seq ?? 0) : String(a.conn).localeCompare(String(b.conn))));
  for (let index = 0; index < ordered.length; index += 1) {
    const call = ordered[index];
    if (!call.error) continue;
    const code = call.error.code ?? "unknown";
    const entry = errors.get(code) ?? { code, count: 0, tools: new Map(), example: null, recovery_tool: null, followed: 0, hinted: 0, traces: [] };
    entry.count += 1;
    increment(entry.tools, call.tool);
    entry.example ??= call.error.message;
    if (call.error.recovery_tool) {
      entry.recovery_tool ??= call.error.recovery_tool;
      entry.hinted += 1;
      const next = ordered[index + 1];
      if (next && next.conn === call.conn && next.tool === call.error.recovery_tool) entry.followed += 1;
    }
    if (entry.traces.length < 3) entry.traces.push(call.trace);
    errors.set(code, entry);
  }
  const errorList = [...errors.values()].map((entry) => ({
    ...entry, tools: Object.fromEntries(entry.tools),
    recovery_followed_rate: entry.hinted ? entry.followed / entry.hinted : null,
  })).sort((a, b) => b.count - a.count);

  // Friction signals.
  const retries = calls.filter((call) => call.repeat && call.after_error);
  const invalidArguments = new Map();
  for (const call of calls.filter((call) => call.error?.code === "invalid_arguments")) {
    const match = /unexpected argument\(s\): ([^;]+)/.exec(call.error.message ?? "");
    for (const name of (match?.[1] ?? "(other validation)").split(",").map((value) => value.trim())) {
      increment(invalidArguments, `${call.tool}: ${name}`);
    }
  }
  let rereadAfterObserve = 0;
  let rereadAfterAction = 0;
  for (let index = 1; index < ordered.length; index += 1) {
    const previous = ordered[index - 1];
    const call = ordered[index];
    if (call.conn !== previous.conn || !readTools.has(call.tool) || !actionTools.has(previous.tool) || previous.error) continue;
    rereadAfterAction += 1;
    if (previous.observe?.appended) rereadAfterObserve += 1;
  }
  const count = (predicate) => calls.filter(predicate).length;
  const signals = {
    retry_loops: retries.length,
    invalid_arguments: Object.fromEntries([...invalidArguments.entries()].sort((a, b) => b[1] - a[1])),
    reread_after_action: rereadAfterAction,
    reread_despite_observe: rereadAfterObserve,
    truncated_reads: count((call) => call.truncated),
    unconfirmed_actions: count((call) => call.action?.outcome === "unconfirmed"),
    wait_timeouts: count((call) => call.wait?.outcome === "timeout"),
    isolation_partial: count((call) => call.isolation === "partial"),
    isolation_breached: count((call) => call.isolation === "breached"),
    screenshots: count((call) => call.tool === "spaceo_screenshot"),
    daemon_drift_notes: count((call) => (call.notes ?? []).some((note) => note.includes("daemon"))),
    sessions_not_destroyed: [...connections.values()].reduce((sum, connection) =>
      sum + [...connection.sessions].filter((session) => !connection.destroyed.has(session)).length, 0),
  };

  const byTokens = [...calls].sort((a, b) => (b.result?.est_tokens ?? 0) - (a.result?.est_tokens ?? 0)).slice(0, top)
    .map((call) => ({ tool: call.tool, tokens: call.result?.est_tokens ?? 0, trace: call.trace, first_line: call.result?.first_line }));
  const slowest = [...calls].sort((a, b) => (b.ms ?? 0) - (a.ms ?? 0)).slice(0, top)
    .map((call) => ({ tool: call.tool, ms: call.ms, trace: call.trace, outcome: call.outcome }));

  // Daemon log: every surface (CLI, Viewer, MCP) and the daemon-side time for journaled traces.
  const daemonFailures = new Map();
  const daemonByClient = new Map();
  const daemonMsByTrace = new Map();
  for (const record of daemonRecords.filter(inRange)) {
    if (record.kind !== "request.failed" && record.kind !== "request.ok") continue;
    increment(daemonByClient, record.client ?? "unlabelled");
    if (record.trace && record.ms) daemonMsByTrace.set(record.trace, Number(record.ms));
    if (record.kind === "request.failed") increment(daemonFailures, `${record.client ?? "unlabelled"} ${record.cmd}: ${record.error_code ?? "(no code)"}`);
  }
  let overhead = [];
  for (const call of calls) {
    const daemon = daemonMsByTrace.get(call.trace);
    if (daemon !== undefined) overhead.push((call.ms ?? 0) - daemon);
  }

  // Ranked candidates: each names the evidence that would move if the improvement worked.
  const candidates = [];
  for (const entry of errorList.slice(0, top)) {
    const followed = entry.recovery_followed_rate;
    candidates.push({
      weight: entry.count * (followed !== null && followed < 0.5 ? 2 : 1),
      title: `Reduce \`${entry.code}\` (${entry.count}× in ${Object.keys(entry.tools).join(", ")})`,
      evidence: `example: ${String(entry.example ?? "").split("\n")[0].slice(0, 160)}`
        + (followed !== null ? `; recovery \`${entry.recovery_tool}\` followed ${Math.round(followed * 100)}%` : "")
        + `; traces: ${entry.traces.join(", ")}`,
    });
  }
  if (signals.retry_loops) candidates.push({ weight: signals.retry_loops * 2, title: "Agents retry the identical failing call", evidence: `${signals.retry_loops} immediate identical retries after an error — the error text does not say what to change` });
  for (const [name, total] of Object.entries(signals.invalid_arguments).slice(0, 3)) {
    candidates.push({ weight: total * 1.5, title: `Schema friction: ${name}`, evidence: `${total} invalid-argument errors — consider an alias or clearer description` });
  }
  if (signals.reread_despite_observe) candidates.push({ weight: signals.reread_despite_observe, title: "Agents re-read the screen even though the action returned an observe diff", evidence: `${signals.reread_despite_observe} of ${signals.reread_after_action} reads right after an action` });
  const hog = tools.filter((tool) => tool.calls >= 3).sort((a, b) => b.avg_tokens - a.avg_tokens)[0];
  if (hog && hog.avg_tokens > 800) candidates.push({ weight: hog.tokens / 2_000, title: `Shrink \`${hog.tool}\` results`, evidence: `${hog.avg_tokens} estimated tokens per call over ${hog.calls} calls` });
  if (signals.truncated_reads) candidates.push({ weight: signals.truncated_reads, title: "Reads hit their budget", evidence: `${signals.truncated_reads} truncated reads` });
  if (signals.sessions_not_destroyed) candidates.push({ weight: signals.sessions_not_destroyed, title: "Sessions left for the janitor", evidence: `${signals.sessions_not_destroyed} sessions used without a destroy in the same connection` });
  candidates.sort((a, b) => b.weight - a.weight);

  const timestamps = calls.map((call) => call.ts).filter(Boolean).sort();
  return {
    scope: {
      calls: calls.length, connections: connections.size,
      clients: [...new Set([...connections.values()].map((connection) => connection.client).filter(Boolean))],
      first: timestamps[0] ?? null, last: timestamps.at(-1) ?? null,
      sessions: new Set(calls.map((call) => call.session).filter(Boolean)).size,
    },
    tools, errors: errorList, signals, token_hogs: byTokens, slowest,
    daemon: {
      requests_by_client: Object.fromEntries(daemonByClient),
      failures: Object.fromEntries([...daemonFailures.entries()].sort((a, b) => b[1] - a[1]).slice(0, top)),
      mcp_overhead_p50_ms: percentile(overhead, 0.5),
    },
    candidates: candidates.slice(0, top),
  };
}

export function renderMarkdown(report) {
  const lines = [];
  const pct = (value) => (value === null || value === undefined ? "—" : `${Math.round(value * 100)}%`);
  lines.push("# SpaceO improvement-loop report", "");
  const scope = report.scope;
  lines.push(`${scope.calls} tool calls across ${scope.connections} connection(s) and ${scope.sessions} session(s)`
    + (scope.first ? `, ${scope.first} → ${scope.last}` : "") + (scope.clients.length ? `; clients: ${scope.clients.join(", ")}` : ""), "");
  lines.push("## Ranked candidates", "");
  if (!report.candidates.length) lines.push("No friction signals yet — use SpaceO through an agent, then run this again.");
  report.candidates.forEach((candidate, index) => lines.push(`${index + 1}. **${candidate.title}** — ${candidate.evidence}`));
  lines.push("", "## Tools", "", "| tool | calls | errors | p50 ms | p95 ms | avg tokens |", "|---|---:|---:|---:|---:|---:|");
  for (const tool of report.tools) lines.push(`| ${tool.tool} | ${tool.calls} | ${tool.errors} (${pct(tool.error_rate)}) | ${tool.p50_ms ?? "—"} | ${tool.p95_ms ?? "—"} | ${tool.avg_tokens} |`);
  lines.push("", "## Errors", "", "| code | count | tools | recovery followed | example |", "|---|---:|---|---:|---|");
  for (const error of report.errors) {
    const example = String(error.example ?? "").split("\n")[0].replaceAll("|", "\\|").slice(0, 140);
    lines.push(`| ${error.code} | ${error.count} | ${Object.keys(error.tools).join(", ")} | ${pct(error.recovery_followed_rate)} | ${example} |`);
  }
  lines.push("", "## Friction signals", "");
  for (const [name, value] of Object.entries(report.signals)) {
    const shown = typeof value === "object" ? (Object.keys(value).length ? JSON.stringify(value) : "none") : value;
    lines.push(`- ${name.replaceAll("_", " ")}: ${shown}`);
  }
  lines.push("", "## Largest results (tokens)", "");
  for (const hog of report.token_hogs) lines.push(`- ${hog.tokens} · ${hog.tool} · \`${hog.trace}\` · ${String(hog.first_line ?? "").slice(0, 100)}`);
  lines.push("", "## Slowest calls", "");
  for (const slow of report.slowest) lines.push(`- ${slow.ms} ms · ${slow.tool} · ${slow.outcome} · \`${slow.trace}\``);
  lines.push("", "## Daemon (all clients)", "");
  lines.push(`- requests by client: ${JSON.stringify(report.daemon.requests_by_client)}`);
  lines.push(`- MCP overhead over daemon time (p50): ${report.daemon.mcp_overhead_p50_ms ?? "—"} ms`);
  for (const [failure, total] of Object.entries(report.daemon.failures)) lines.push(`- ${total}× ${failure}`);
  lines.push("", "Open a trace: `grep -r <trace> ~/Library/Logs/SpaceO/journal ~/Library/Logs/SpaceO/daemon.log`");
  return lines.join("\n");
}

function main() {
  const options = parseArguments(process.argv.slice(2));
  const budget = { bytes: 0 };
  const journalFiles = options.inputs.flatMap((input) => listFiles(input, /\.jsonl$/));
  const daemonFiles = options.daemonLogs.flatMap((input) => listFiles(input, /^daemon\.log(\.1)?$/));
  const journal = readJSONLines(journalFiles, budget);
  const daemon = readJSONLines(daemonFiles, budget);
  const report = analyze(journal.records, daemon.records, options);
  report.sources = { journal_files: journalFiles.length, daemon_files: daemonFiles.length, invalid_lines: journal.invalid + daemon.invalid };
  console.log(options.json ? JSON.stringify(report, null, 2) : renderMarkdown(report));
}

if (import.meta.url === `file://${process.argv[1]}`) main();
