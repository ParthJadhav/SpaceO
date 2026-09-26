import assert from "node:assert/strict";
import test from "node:test";
import { imagesChanged, isolationStatus, toolResult } from "../scripts/computer-use-evidence.mjs";

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

test("matrix exits with failure when its MCP process cannot start or exits early", () => {
  const root = mkdtempSync(join(tmpdir(), "spaceo-matrix-test-"));
  try {
    for (const binary of [join(root, "missing"), "/usr/bin/false"]) {
      const run = spawnSync(process.execPath, [matrix, binary, "--suite=native"], {
        encoding: "utf8", timeout: 5_000, env: { ...process.env, TMPDIR: root, SPACEO_LIVE_TESTS: "1" },
      });
      assert.equal(run.error, undefined, "the harness must finish without an external timeout");
      assert.equal(run.status, 1);
      assert.match(run.stdout, /FAIL  harness error/);
      assert.deepEqual(readdirSync(root), [], "all generated fixtures must be removed");
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
  else if (request.method === 'tools/list') response.result = {tools:Array.from({length:34}, (_, index) => ({name:'test' + index}))};
  else response.error = {code:-32602, message:'PRIVATE-DIAGNOSTIC'};
  console.log(JSON.stringify(response));
});
`, { mode: 0o700 });
    const run = spawnSync(process.execPath, [matrix, binary, "--suite=all", `--report=${report}`], {
      encoding: "utf8", timeout: 5_000, env: {
        ...process.env, TMPDIR: root, SPACEO_LIVE_TESTS: "1", SPACEO_CU_CHROME_APP: root, SPACEO_CU_CURSOR_APP: root,
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
