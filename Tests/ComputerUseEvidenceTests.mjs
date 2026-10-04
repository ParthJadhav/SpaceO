import assert from "node:assert/strict";
import test from "node:test";
import { imagesChanged, isolationStatus, isolationDiagnostics, toolResult,
  fixturePageState, pageElementFor } from "../scripts/computer-use-evidence.mjs";

test("failed window observations never become absent fixture events", () => {
  assert.deepEqual(fixturePageState({ ok: false, text: "CU ev=hover y=0" }),
    { ok: false, reason: "tool_failed" });
  assert.deepEqual(fixturePageState({ ok: true, text: "other window" }),
    { ok: false, reason: "fixture_state_missing" });
  assert.deepEqual(fixturePageState({ ok: true, text: "CU ev=none y=0" }),
    { ok: true, events: [], scrollY: 0, raw: "CU ev=none y=0" });
  assert.deepEqual(fixturePageState({ ok: true, text: "CU ev=click+hover y=123" }),
    { ok: true, events: ["click", "hover"], scrollY: 123, raw: "CU ev=click+hover y=123" });
});

test("page targets use exact labels and current web references without coordinate guesses", () => {
  const text = "  [2] button — HOVER ME  at (1,2)\n"
    + "  [w1] div — HOVER ME TOO  at (3,4)\n"
    + "  [w7] div — HOVER ME  at (90,110)\n"
    + "  [w9] input type=text — type here  at (200,150)";
  assert.deepEqual(pageElementFor({ ok: true, text }, "HOVER ME"),
    { element: "w7", x: 90, y: 110 });
  assert.deepEqual(pageElementFor({ ok: true, text }, "type here"),
    { element: "w9", x: 200, y: 150 });
  assert.equal(pageElementFor({ ok: false, text }, "HOVER ME"), null);
  assert.equal(pageElementFor({ ok: true, text }, "missing"), null);
  for (const suffix of ["at (-1,3)", "at (1,3)  (disabled)", "without coordinates"]) {
    assert.equal(pageElementFor({ ok: true, text: "[w0] div — HOVER ME  " + suffix }, "HOVER ME"), null);
  }
});

test("isolation follow-up retains fixed codes without private evidence", () => {
  const result = isolationDiagnostics({ ok: false, text: "ISOLATION BREACH\n"
    + "- cursor_location: failed [observed] — private coordinates\n  failure: private data\n"
    + "- key_input_route: unknown [unknown] — private process\n"
    + "- window_server_front_process: passed [inferred] — private process\n"
    + "- private_name: passed [observed] — app content" });
  assert.deepEqual(result, { observed: true, checks: {
    cursor_location: { status: "failed", coverage: "observed" },
    key_input_route: { status: "unknown", coverage: "unknown" },
    window_server_front_process: { status: "passed", coverage: "inferred" },
  }});
  assert.equal(JSON.stringify(result).includes("private"), false);
  assert.deepEqual(isolationDiagnostics(null), { observed: false });
  assert.deepEqual(isolationDiagnostics({ text: "- cursor_location: failed [observed]\n"
    + "- cursor_location: passed [observed]" }), { observed: false });
});

test("JSON-RPC errors and missing tool results never count as success", () => {
  for (const response of [null, {}, { result: {} }, { result: { content: null } },
    { error: { code: -32602, message: "invalid params" } }]) {
    assert.equal(toolResult(response).ok, false);
  }
});

test("tool errors preserve their failure and diagnostic", () => {
  const response = toolResult({ result: { isError: true,
    content: [{ type: "text", text: "capture refused" }] } });
  assert.equal(response.ok, false);
  assert.equal(response.text, "capture refused");
});

test("successful tools preserve image and unconfirmed delivery evidence", () => {
  const response = toolResult({ result: { content: [
    { type: "text", text: "UNCONFIRMED: posted only" }, { type: "image", data: "image" },
  ] } });
  assert.equal(response.ok, true);
  assert.equal(response.image, "image");
  assert.equal(response.unconfirmed, true);
});

test("a missing or failed screenshot is not a visual change", () => {
  const before = { ok: true, image: "before" };
  assert.equal(imagesChanged(before, { ok: true, image: "after" }), true);
  for (const after of [{ ok: false, image: "after" }, { ok: true, image: null },
    { ok: true, image: "" }, before]) {
    assert.equal(imagesChanged(before, after), false);
    assert.equal(imagesChanged(after, before), false);
  }
});

test("only explicit intact isolation passes", () => {
  assert.equal(isolationStatus({ ok: true, text: "  isolation: intact (inferred)" }), "pass");
  assert.equal(isolationStatus({ ok: true, text: "isolation: partial (unknown route)" }), "blocked");
  for (const text of ["", "all good", "isolation: breached", "isolation: intact-ish"]) {
    assert.equal(isolationStatus({ ok: true, text }), "fail");
  }
  assert.equal(isolationStatus({ ok: false, text: "isolation: intact" }), "fail");
});

// Run only against inert stand-ins: these checks never invoke SpaceO, apps, or WindowServer.
import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
const matrix = fileURLToPath(new URL("../scripts/computer-use-check.mjs", import.meta.url));

function quietHostEnvironment(root) {
  // Stub only the read-only preflight; keep these MCP fixtures independent of the host.
  writeFileSync(join(root, "python3"), "#!/bin/sh\nexit 0\n", { mode: 0o700 });
  return { ...process.env, TMPDIR: root, SPACEO_LIVE_TESTS: "1", PATH: `${root}:${process.env.PATH}` };
}

test("matrix exits with failure when its MCP process cannot start or exits early", () => {
  const root = mkdtempSync(join(tmpdir(), "spaceo-matrix-test-"));
  try {
    for (const binary of [join(root, "missing"), "/usr/bin/false"]) {
      const run = spawnSync(process.execPath, [matrix, binary, "--suite=native"], {
        encoding: "utf8", timeout: 5_000, env: quietHostEnvironment(root),
      });
      assert.equal(run.error, undefined, "the harness must finish without an external timeout");
      assert.equal(run.status, 1);
      assert.match(run.stdout, /FAIL  harness error/);
      assert.deepEqual(readdirSync(root), ["python3"], "all generated fixtures must be removed");
    }
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("matrix stops after its first suite failure and keeps diagnostics out of labels", () => {
  const root = mkdtempSync(join(tmpdir(), "spaceo-matrix-test-"));
  try {
    const binary = join(root, "fake-mcp.mjs");
    const report = join(root, "report.json");
    writeFileSync(binary, `#!${process.execPath}
import { createInterface } from 'node:readline';
createInterface({input: process.stdin}).on('line', line => {
  const request = JSON.parse(line);
  let response = {jsonrpc:'2.0', id:request.id};
  if (request.method === 'initialize') response.result = {protocolVersion:'2025-11-25'};
  else if (request.method === 'tools/list') response.result = {tools:Array.from({length:35}, (_, index) => ({name:'test' + index}))};
  else response.error = {code:-32602, message:'PRIVATE-DIAGNOSTIC'};
  console.log(JSON.stringify(response));
});
`, { mode: 0o700 });
    const run = spawnSync(process.execPath, [matrix, binary, "--suite=all", `--report=${report}`], {
      encoding: "utf8", timeout: 5_000, env: {
        ...quietHostEnvironment(root), SPACEO_CU_CHROME_APP: root, SPACEO_CU_CURSOR_APP: root,
      },
    });
    assert.equal(run.error, undefined);
    assert.equal(run.status, 1);
    assert.doesNotMatch(run.stdout, /launch TextEdit/);
    const result = JSON.parse(readFileSync(report, "utf8"));
    assert.equal(result.tools[0].tool, "spaceo_session_create");
    assert.equal(result.tools[0].ok, false);
    assert.deepEqual(result.steps.filter(step => step.status === "fail").map(step => step.label),
      ["[native] suite error"]);
    assert.equal(result.tools.length, 1, "later suites must not create another display");
    assert.doesNotMatch(JSON.stringify(result.steps), /PRIVATE-DIAGNOSTIC/);
    assert.equal(readdirSync(root).some(name => name.startsWith("spaceo-cu-")), false);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("matrix refuses to start without reserved-host opt-in", () => {
  const run = spawnSync(process.execPath, [matrix, "/usr/bin/false"], {
    encoding: "utf8", timeout: 5_000, env: { ...process.env, SPACEO_LIVE_TESTS: "0" },
  });
  assert.equal(run.status, 1);
  assert.match(run.stderr, /SPACEO_LIVE_TESTS=1/);
  assert.equal(run.stdout, "");
});
