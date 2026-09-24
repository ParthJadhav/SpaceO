import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import { analyze, parseArguments, renderMarkdown } from "../scripts/journal-report.mjs";

const script = join(dirname(fileURLToPath(import.meta.url)), "..", "scripts", "journal-report.mjs");

const call = (seq, tool, extra = {}) => ({
  v: 1, kind: "tool_call", conn: "c1", seq, tool, trace: `t${seq}`, ms: 10 * seq,
  ts: `2026-09-23T10:00:0${seq}Z`, session: "agent-1", outcome: "ok",
  result: { est_tokens: 50, first_line: `${tool} result` }, ...extra,
});

function fixture() {
  const stale = { code: "stale_snapshot", message: "there is no current accessibility snapshot", recovery_tool: "spaceo_read_screen" };
  return [
    { v: 1, kind: "connection.start", conn: "c1", client: { name: "claude-code", version: "2.1" }, ts: "2026-09-23T10:00:00Z" },
    call(1, "spaceo_session_create"),
    call(2, "spaceo_click", { outcome: "tool_error", error: stale }),
    call(3, "spaceo_click", { outcome: "tool_error", error: stale, repeat: true, after_error: true }),
    call(4, "spaceo_read_screen", { result: { est_tokens: 2_400, first_line: "snapshot: s1" }, truncated: "traversal_budget" }),
    call(5, "spaceo_click", { observe: { mode: "diff", appended: true }, action: { outcome: "confirmed" } }),
    call(6, "spaceo_read_screen"),
    call(7, "spaceo_type", { outcome: "invalid_arguments", error: { code: "invalid_arguments", message: "unexpected argument(s): session_id; accepted: session" } }),
    { v: 1, kind: "connection.end", conn: "c1", reason: "eof", ts: "2026-09-23T10:00:09Z" },
  ];
}

test("analysis ranks repeated errors, retries, schema friction and re-reads", () => {
  const report = analyze(fixture(), [
    { kind: "request.failed", client: "viewer", cmd: "session.control", error_code: "unknown_session", ms: "3" },
    { kind: "request.ok", client: "mcp", cmd: "click", trace: "t5", ms: "20" },
  ]);
  assert.equal(report.scope.calls, 7);
  assert.deepEqual(report.scope.clients, ["claude-code 2.1"]);
  const stale = report.errors.find((error) => error.code === "stale_snapshot");
  assert.equal(stale.count, 2);
  assert.equal(stale.recovery_followed_rate, 0.5, "the second stale error was followed by a read");
  assert.equal(report.signals.retry_loops, 1);
  assert.deepEqual(report.signals.invalid_arguments, { "spaceo_type: session_id": 1 });
  assert.equal(report.signals.reread_despite_observe, 1);
  assert.equal(report.signals.truncated_reads, 1);
  assert.equal(report.signals.sessions_not_destroyed, 1);
  assert.equal(report.token_hogs[0].trace, "t4");
  assert.equal(report.daemon.requests_by_client.viewer, 1);
  assert.equal(report.daemon.mcp_overhead_p50_ms, 30, "MCP time minus daemon time for a joined trace");
  assert.match(report.candidates[0].title, /stale_snapshot/);
  const markdown = renderMarkdown(report);
  assert.match(markdown, /## Ranked candidates/);
  assert.match(markdown, /\| stale_snapshot \| 2 \|/);
});

test("since filters by timestamp and argument parsing is strict", () => {
  assert.equal(analyze(fixture(), [], { since: "2026-09-23T10:00:05Z" }).scope.calls, 3);
  assert.throws(() => parseArguments(["--bogus"]), /unknown option/);
  assert.deepEqual(parseArguments(["dir", "--daemon-log", "d.log", "--top=3"]).daemonLogs, ["d.log"]);
});

test("the CLI reads a journal directory recursively and prints JSON", () => {
  const root = mkdtempSync(join(tmpdir(), "spaceo-journal-report-"));
  try {
    const day = join(root, "2026-09-23");
    mkdirSync(day);
    writeFileSync(join(day, "mcp-1-c1.jsonl"), fixture().map((record) => JSON.stringify(record)).join("\n") + "\nnot json\n");
    const output = JSON.parse(execFileSync(process.execPath, [script, root, "--json"], { encoding: "utf8" }));
    assert.equal(output.scope.calls, 7);
    assert.equal(output.sources.invalid_lines, 1);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
