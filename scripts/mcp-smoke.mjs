#!/usr/bin/env node

import { spawn, spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { createInterface } from "node:readline";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const binary = resolve(process.argv[2] ?? ".build/release/spaceo");
const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const expectedVersion = (
  process.env.SPACEO_EXPECTED_VERSION
  ?? readFileSync(resolve(scriptDirectory, "../VERSION"), "utf8")
).trim();
const socket = `/tmp/spaceo-mcp-smoke-${process.pid}.sock`;
const server = spawn(binary, ["mcp", "--socket", socket], {
  stdio: ["pipe", "pipe", "pipe"],
});

let diagnostics = "";
server.stderr.setEncoding("utf8");
server.stderr.on("data", (chunk) => {
  diagnostics += chunk;
});

const lines = [];
const waiters = [];
const reader = createInterface({ input: server.stdout });
reader.on("line", (line) => {
  const waiter = waiters.shift();
  if (waiter) waiter.resolve(line);
  else lines.push(line);
});

function nextLine(timeout = 12_000) {
  if (lines.length) return Promise.resolve(lines.shift());
  return new Promise((resolveLine, reject) => {
    const waiter = {
      resolve: (line) => {
        clearTimeout(timer);
        resolveLine(line);
      },
    };
    const timer = setTimeout(() => {
      const index = waiters.indexOf(waiter);
      if (index >= 0) waiters.splice(index, 1);
      reject(new Error(`MCP response timed out. Diagnostics:\n${diagnostics}`));
    }, timeout);
    waiters.push(waiter);
  });
}

async function exchange(message) {
  server.stdin.write(`${JSON.stringify(message)}\n`);
  return JSON.parse(await nextLine());
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

async function waitForSocketRemoval(timeout = 5_000) {
  const deadline = Date.now() + timeout;
  while (existsSync(socket) && Date.now() < deadline) {
    await new Promise((resolveDelay) => setTimeout(resolveDelay, 25));
  }
  assert(!existsSync(socket), `daemon socket still exists after cleanup: ${socket}`);
}

let nextID = 1;
function request(method, params = {}) {
  return exchange({ jsonrpc: "2.0", id: nextID++, method, params });
}

try {
  const initialized = await request("initialize", {
    protocolVersion: "2099-01-01",
    capabilities: {},
    clientInfo: { name: "spaceo-smoke", version: "1" },
  });
  assert(
    initialized.result?.protocolVersion === "2025-11-25",
    `unexpected protocol negotiation: ${JSON.stringify(initialized)}`,
  );
  assert(
    initialized.result?.serverInfo?.version === expectedVersion,
    `MCP server did not advertise release version ${expectedVersion}`,
  );
  assert(
    initialized.result?.instructions?.includes("isolates attention, not security"),
    "MCP instructions did not disclose the security-boundary limitation",
  );

  const listed = await request("tools/list");
  const tools = listed.result?.tools ?? [];
  assert(tools.length === 16, `expected 16 tools, got ${tools.length}`);
  assert(
    new Set(tools.map((tool) => tool.name)).size === tools.length,
    "tool names are not unique",
  );

  // Without these an agent cannot reach anything below the fold, cannot open a hover-only menu,
  // and cannot move a slider — the ordinary steps a computer-use agent takes on real UI.
  for (const required of ["spaceo_scroll", "spaceo_move", "spaceo_drag"]) {
    assert(
      tools.some((tool) => tool.name === required),
      `${required} is missing from the advertised tool set`,
    );
  }

  const droppedModifiers = await request("tools/call", {
    name: "spaceo_click",
    arguments: { element: "3", modifiers: ["shift"] },
  });
  assert(
    droppedModifiers.result?.isError === true,
    "a modifier-held click on an element index must fail rather than silently press",
  );

  const badButton = await request("tools/call", {
    name: "spaceo_click",
    arguments: { x: 1, y: 1, button: "sideways" },
  });
  assert(
    badButton.result?.isError === true,
    "an unknown mouse button was not rejected",
  );

  const partialRegion = await request("tools/call", {
    name: "spaceo_screenshot",
    arguments: { x: 0, y: 0, width: 10 },
  });
  assert(
    partialRegion.result?.isError === true,
    "an incomplete screenshot region was not rejected",
  );

  const negativeWindow = await request("tools/call", {
    name: "spaceo_screenshot",
    arguments: { window: -1 },
  });
  assert(
    negativeWindow.result?.isError === true,
    "negative window id was not returned as a tool error",
  );

  const invalidParams = await exchange({
    jsonrpc: "2.0",
    id: nextID++,
    method: "tools/list",
    params: [],
  });
  assert(invalidParams.error?.code === -32602, "array params were not rejected");

  server.stdin.write("[1,2,3]\n");
  const invalidRequest = JSON.parse(await nextLine());
  assert(invalidRequest.error?.code === -32600, "non-object request was not rejected");

  server.stdin.write("{not-json}\n");
  const parseError = JSON.parse(await nextLine());
  assert(parseError.error?.code === -32700, "malformed JSON was not a parse error");

  // An id-less tool call must never mutate GUI state: the caller would have no response from
  // which to learn the generated session id and therefore no reliable way to tear it down.
  server.stdin.write(`${JSON.stringify({
    jsonrpc: "2.0",
    method: "tools/call",
    params: { name: "spaceo_session_create", arguments: { name: "must-not-exist" } },
  })}\n`);

  const sessions = await request("tools/call", {
    name: "spaceo_session_list",
    arguments: {},
  });
  const sessionText = sessions.result?.content?.[0]?.text ?? "";
  assert(sessionText.includes("no sessions"), "id-less tool call created a session");

  const invalidCLI = spawnSync(
    binary,
    ["screenshot", "--window", "not-a-number", "--socket", socket],
    { encoding: "utf8", timeout: 5_000 },
  );
  assert(invalidCLI.status !== 0, "invalid CLI window id unexpectedly succeeded");
  assert(
    invalidCLI.stderr.includes("--window must be an integer"),
    `invalid CLI window id was silently ignored: ${invalidCLI.stderr}`,
  );

  const unknownOption = spawnSync(binary, ["version", "--sesion", "typo"], {
    encoding: "utf8",
    timeout: 5_000,
  });
  assert(unknownOption.status !== 0, "unknown CLI option unexpectedly succeeded");
  assert(
    unknownOption.stderr.includes("unknown option"),
    `unknown CLI option was not explained: ${unknownOption.stderr}`,
  );

  for (const invalidSize of [
    "1920x1080xgarbage",
    "1920xx1080",
    "9223372036854775807x1080",
  ]) {
    const invalidDisplay = spawnSync(
      binary,
      ["daemon", "--display-size", invalidSize, "--socket", `${socket}.invalid`],
      { encoding: "utf8", timeout: 5_000 },
    );
    assert(
      invalidDisplay.status !== 0,
      `invalid display size unexpectedly started a daemon: ${invalidSize}`,
    );
  }

  server.stdin.end();
  const exitCode = await new Promise((resolveExit, reject) => {
    server.once("error", reject);
    server.once("exit", resolveExit);
  });
  assert(exitCode === 0, `MCP process exited ${exitCode}. Diagnostics:\n${diagnostics}`);

  console.log(
    "MCP smoke passed: protocol, 16 tools, validation, mutation safety, and clean exit",
  );
} finally {
  if (!server.killed) server.kill("SIGTERM");
  spawnSync(binary, ["daemon", "stop", "--socket", socket], {
    stdio: "ignore",
    timeout: 5_000,
  });
  await waitForSocketRemoval();
}
