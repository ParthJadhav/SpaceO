#!/usr/bin/env node

// Turn the MCP agent journal (and optionally the daemon log) into an improvement-loop report:
// where agents spend calls, tokens and time, which errors they hit, whether they follow the
// recovery hints, and which friction patterns recur — ranked, with example traces to open.
//
// usage: node scripts/journal-report.mjs [JOURNAL_DIR_OR_FILE ...] [--daemon-log FILE ...]
//                                        [--since=YYYY-MM-DD] [--top=N] [--json]
// default journal dir: ~/Library/Logs/SpaceO/journal
//
// Everything stays local. Error messages and first result lines may contain private app
// content, so the rendered report must remain private too. Full result text is not retained.

import { closeSync, constants, fstatSync, lstatSync, openSync, opendirSync, readSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const maximumFileBytes = 64 * 1_048_576;
const maximumTotalBytes = 512 * 1_048_576;
const maximumEntries = 10_000;
const maximumDepth = 16;
const maximumRecords = 500_000;
const maximumLineBytes = 1_048_576;

export function parseArguments(argv) {
  const options = { inputs: [], daemonLogs: [], since: null, top: 10, json: false };
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === "--json") options.json = true;
    else if (value.startsWith("--since=")) options.since = value.slice(8);
    else if (value.startsWith("--top=")) options.top = Math.max(1, Math.min(100, Number(value.slice(6)) || 10));
    else if (value === "--daemon-log") {
      const path = argv[++index];
      if (!path || path.startsWith("--")) throw new Error("--daemon-log requires a path");
      options.daemonLogs.push(path);
    }
    else if (value.startsWith("--daemon-log=")) options.daemonLogs.push(value.slice(13));
    else if (value.startsWith("--")) throw new Error(`unknown option ${value}`);
    else options.inputs.push(value);
  }
  if (options.daemonLogs.some((path) => !path)) throw new Error("--daemon-log requires a path");
  if (options.since !== null) {
    const date = new Date(options.since);
    if (!/^\d{4}-\d{2}-\d{2}$/.test(options.since)
        || !Number.isFinite(date.getTime()) || date.toISOString().slice(0, 10) !== options.since) {
      throw new Error("--since requires a valid YYYY-MM-DD date");
    }
  }
  if (!options.inputs.length) options.inputs.push(join(homedir(), "Library/Logs/SpaceO/journal"));
  return options;
}

function listFiles(path, pattern, discovery, depth = 0, explicit = true) {
  if (depth > maximumDepth) throw new Error(`refusing directories deeper than ${maximumDepth}`);
  let info;
  try { info = lstatSync(path); } catch (error) {
    if (error.code === "ENOENT") return [];
    throw error;
  }
  // Follow explicit file aliases only. Directory links must never recurse or hide a cycle.
  if (info.isSymbolicLink()) {
    if (!explicit) return [];
    const resolved = realpathSync(path);
    if (!lstatSync(resolved).isFile()) throw new Error("input link must name a regular file");
    path = resolved;
    info = lstatSync(path);
  }
  const resolved = realpathSync(path);
  if (discovery.seen.has(resolved)) return [];
  discovery.seen.add(resolved);
  if (info.isFile()) return [resolved];
  if (!info.isDirectory()) throw new Error("report inputs must be regular files or directories");
  const found = [];
  const directory = opendirSync(path);
  try {
    for (let entry; (entry = directory.readSync()) !== null;) {
      if (++discovery.entries > maximumEntries) throw new Error(`refusing more than ${maximumEntries} directory entries`);
      const child = join(path, entry.name);
      if (entry.isDirectory()) found.push(...listFiles(child, pattern, discovery, depth + 1, false));
      else if (pattern.test(entry.name)) found.push(...listFiles(child, pattern, discovery, depth + 1, false));
    }
  } finally { directory.closeSync(); }
  return found.sort();
}

export function readJSONLines(files, budget) {
  const records = [];
  let invalid = 0;
  for (const file of files) {
    const descriptor = openSync(file, constants.O_RDONLY | constants.O_NONBLOCK);
    try {
      const info = fstatSync(descriptor);
      if (!info.isFile()) throw new Error("report inputs must be regular files");
      if (info.size > maximumFileBytes) throw new Error(`refusing a file larger than ${maximumFileBytes} bytes`);
      const chunk = Buffer.alloc(64 * 1_024);
      let fileBytes = 0;
      let pending = Buffer.alloc(0);
      const parseLine = (line) => {
        if (line.length > maximumLineBytes) throw new Error(`refusing a line larger than ${maximumLineBytes} bytes`);
        if (!line.toString("utf8").trim()) return;
        if (++budget.lines > maximumRecords) throw new Error(`refusing more than ${maximumRecords} records`);
        try {
          const record = JSON.parse(line.toString("utf8"));
          if (!record || typeof record !== "object" || Array.isArray(record)) { invalid += 1; return; }
          // Analysis never needs rendered application content. Do not retain it in memory.
          if (record.result && typeof record.result === "object") delete record.result.text;
          records.push(record);
        } catch { invalid += 1; }
      };
      budget.lines ??= 0;
      for (;;) {
        const count = readSync(descriptor, chunk, 0, chunk.length, null);
        if (!count) break;
        fileBytes += count;
        budget.bytes += count;
        if (fileBytes > maximumFileBytes || budget.bytes > maximumTotalBytes) throw new Error("report input byte budget exceeded");
        const data = Buffer.concat([pending, chunk.subarray(0, count)]);
        let start = 0;
        for (let index = 0; index < data.length; index += 1) {
          if (data[index] !== 10) continue;
          parseLine(data.subarray(start, index));
          start = index + 1;
        }
        pending = Buffer.from(data.subarray(start));
        if (pending.length > maximumLineBytes) throw new Error(`refusing a line larger than ${maximumLineBytes} bytes`);
      }
      if (pending.length) parseLine(pending);
    } finally { closeSync(descriptor); }
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
const protectedRefusals = new Set(["display_creation_failed", "isolation_breached", "unsupported_target",
  "resource_limit", "session_paused", "lease_required", "isolation_requirements_unmet"]);

export function analyze(journalRecords, daemonRecords = [], { since = null, top = 10 } = {}) {
  const inRange = (record) => !since || (record.ts ?? "") >= since;
  const calls = journalRecords.filter((record) => record.kind === "tool_call" && inRange(record));
  const successful = (record) => ["ok", "warning"].includes(record.outcome)
    && !record.error && record.result?.is_error !== true;
  const connections = new Map();
  // Preserve ownership and client context before --since. Session names in failed calls or
  // observer reads are not evidence that this connection acquired a session.
  const history = [...journalRecords].sort((a, b) => String(a.ts ?? "").localeCompare(String(b.ts ?? ""))
    || (a.seq ?? 0) - (b.seq ?? 0));
  for (const record of history) {
    const connection = connections.get(record.conn) ?? { client: null, ended: false, included: false, sessions: new Map() };
    connection.included ||= inRange(record);
    if (record.client?.name) connection.client = `${record.client.name} ${record.client.version ?? ""}`.trim();
    if (record.kind === "connection.end") {
      connection.ended = true;
      if (inRange(record)) {
        for (const session of connection.sessions.keys()) connection.sessions.set(session, true);
      }
    }
    if (record.kind === "tool_call") {
      if (record.session && connection.sessions.has(record.session) && inRange(record)) connection.sessions.set(record.session, true);
      // New journals explicitly record returned ownership even when create-and-open fails.
      // Older journals only prove acquisition on a successful create/claim.
      const acquired = record.session_lifecycle?.acquired
        ?? (successful(record) && ["spaceo_session_create", "spaceo_session_claim"].includes(record.tool) ? record.session : null);
      if (acquired) connection.sessions.set(acquired, inRange(record));
      if (successful(record) && record.tool === "spaceo_session_destroy" && record.args?.all === true) {
        connection.sessions.clear();
      } else if (Array.isArray(record.session_lifecycle?.released)) {
        for (const session of record.session_lifecycle.released) connection.sessions.delete(session);
      } else if (successful(record) && record.tool === "spaceo_session_destroy") {
        if (record.args?.all === true) connection.sessions.clear();
        else if (record.session) connection.sessions.delete(record.session);
        else if (connection.sessions.size === 1) connection.sessions.clear();
      }
      if (record.outcome === "daemon_restarted") connection.sessions.clear();
    }
    connections.set(record.conn, connection);
  }
  const includedConnections = [...connections.values()].filter((connection) => connection.included);
  const remaining = (connection) => [...connection.sessions.values()].filter(Boolean).length;

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
    if (call.conn !== previous.conn || !readTools.has(call.tool) || !actionTools.has(previous.tool) || !successful(previous)) continue;
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
    sessions_not_destroyed: includedConnections.filter((connection) => connection.ended)
      .reduce((sum, connection) => sum + remaining(connection), 0),
    sessions_still_open: includedConnections.filter((connection) => !connection.ended)
      .reduce((sum, connection) => sum + remaining(connection), 0),
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
      title: `${protectedRefusals.has(entry.code) ? "Inspect protected refusal" : "Investigate"} \`${entry.code}\` (${entry.count}× in ${Object.keys(entry.tools).join(", ")})`,
      evidence: `example: ${String(entry.example ?? "").split("\n")[0].slice(0, 160)}`
        + (followed !== null ? `; recovery \`${entry.recovery_tool}\` followed ${Math.round(followed * 100)}%` : "")
        + `; traces: ${entry.traces.join(", ")}`,
    });
  }
  if (signals.retry_loops) candidates.push({ weight: signals.retry_loops * 2, title: "Agents retry the identical failing call", evidence: `${signals.retry_loops} immediate identical retries after an error — inspect the error and recovery hint before replaying` });
  for (const [name, total] of Object.entries(signals.invalid_arguments).slice(0, 3)) {
    const other = name.endsWith(": (other validation)");
    candidates.push({ weight: total * 1.5,
      title: `${other ? "Validation refusals" : "Schema friction"}: ${name}`,
      evidence: `${total} invalid-argument errors — ${other ? "inspect ownership and prerequisites before changing the schema" : "consider an alias or clearer description"}` });
  }
  if (signals.reread_despite_observe) candidates.push({ weight: signals.reread_despite_observe, title: "Agents re-read the screen even though the action returned an observe diff", evidence: `${signals.reread_despite_observe} of ${signals.reread_after_action} reads right after an action` });
  const hog = tools.filter((tool) => tool.calls >= 3).sort((a, b) => b.avg_tokens - a.avg_tokens)[0];
  if (hog && hog.avg_tokens > 800) candidates.push({ weight: hog.tokens / 2_000, title: `Shrink \`${hog.tool}\` results`, evidence: `${hog.avg_tokens} estimated tokens per call over ${hog.calls} calls` });
  if (signals.truncated_reads) candidates.push({ weight: signals.truncated_reads, title: "Reads hit their budget", evidence: `${signals.truncated_reads} truncated reads` });
  if (signals.sessions_not_destroyed) candidates.push({ weight: signals.sessions_not_destroyed, title: "Session cleanup not observed", evidence: `${signals.sessions_not_destroyed} acquired sessions had no successful destroy before the connection ended; actual janitor cleanup is unknown` });
  candidates.sort((a, b) => b.weight - a.weight);

  const timestamps = calls.map((call) => call.ts).filter(Boolean).sort();
  return {
    scope: {
      calls: calls.length, connections: includedConnections.length,
      clients: [...new Set(includedConnections.map((connection) => connection.client).filter(Boolean))],
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
  const discovery = { seen: new Set(), entries: 0 };
  const journalFiles = options.inputs.flatMap((input) => listFiles(input, /\.jsonl$/, discovery));
  const daemonFiles = options.daemonLogs.flatMap((input) => listFiles(input, /^daemon\.log(\.1)?$/, discovery));
  const journal = readJSONLines(journalFiles, budget);
  const daemon = readJSONLines(daemonFiles, budget);
  const report = analyze(journal.records, daemon.records, options);
  report.sources = { journal_files: journalFiles.length, daemon_files: daemonFiles.length, invalid_lines: journal.invalid + daemon.invalid };
  console.log(options.json ? JSON.stringify(report, null, 2) : renderMarkdown(report));
}

if (import.meta.url === `file://${process.argv[1]}`) main();
