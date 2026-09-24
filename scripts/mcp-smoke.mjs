#!/usr/bin/env node

import { spawn, spawnSync } from "node:child_process";
import { existsSync, readFileSync, rmSync } from "node:fs";
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
// The smoke run auto-starts its own throwaway daemon; point that daemon's failure log at a
// throwaway file too, so smoke noise never lands in the user's real daemon.log.
const server = spawn(binary, ["mcp", "--socket", socket], {
  stdio: ["pipe", "pipe", "pipe"],
  // Smoke traffic is not agent behaviour; keep it out of the host's improvement-loop journal.
  env: { ...process.env, SPACEO_LOG_FILE: `/tmp/spaceo-mcp-smoke-${process.pid}.log`, SPACEO_JOURNAL: "off" },
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
  assert(tools.length === 34, `expected 34 tools, got ${tools.length}`);
  assert(
    new Set(tools.map((tool) => tool.name)).size === tools.length,
    "tool names are not unique",
  );

  // Every agent pays for the catalogue on every connection; keep it lean and self-describing.
  const catalogueBytes = Buffer.byteLength(JSON.stringify(tools));
  assert(catalogueBytes <= 31_000, `tools/list grew to ${catalogueBytes} bytes`);
  const click = tools.find((tool) => tool.name === "spaceo_click");
  assert(click?.inputSchema?.properties?.observe && click.inputSchema.properties.verbose,
    "spaceo_click does not advertise observe/verbose");
  const typo = await request("tools/call", {
    name: "spaceo_click",
    arguments: { session_id: "synthetic", element: "3" },
  });
  const typoText = typo.result?.content?.[0]?.text ?? "";
  assert(typo.result?.isError === true && typoText.includes("accepted: ")
    && typoText.includes("did you mean 'session_id' → 'session'?"),
    `a misspelled argument did not name the accepted ones: ${typoText}`);

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

  const prompts = (await request("prompts/list")).result?.prompts ?? [];
  assert(prompts.length === 3, "expected three playbook prompts");
  for (const prompt of prompts) {
    const argument = prompt.arguments[0];
    assert(argument.description.includes("4096 characters") && argument.description.includes("16384 UTF-8 bytes"),
      "prompt discovery omitted argument limits");
    const expanded = await request("prompts/get", { name: prompt.name, arguments: { [argument.name]: "synthetic" } });
    assert(expanded.result?.messages[0]?.content?.text.startsWith(`${argument.name}: synthetic\n\n`),
      "valid prompt did not preserve its argument");
  }
  for (const argumentsValue of [[], { app: 5 }, { app: "synthetic", ignored: "must be refused" },
    { app: `a${"\u0301".repeat(100_000)}` }]) {
    const invalidPrompt = await request("prompts/get", { name: "drive-app", arguments: argumentsValue });
    assert(invalidPrompt.error?.code === -32602, "malformed prompt arguments were not refused");
    assert(Buffer.byteLength(invalidPrompt.error.message) < 1_024, "prompt error echoed oversized input");
  }
  const recoveredPrompt = await request("prompts/get", { name: "drive-app", arguments: { app: "synthetic" } });
  assert(recoveredPrompt.result?.messages.length === 1, "prompt handling did not recover after malformed input");

  const diagnosticName = `a${"\u0301".repeat(100_000)}`;
  const unknownMethod = await request(diagnosticName);
  assert(unknownMethod.error?.code === -32601, "unknown method lost its error code");
  assert(Buffer.byteLength(unknownMethod.error.message) < 128, "unknown method echoed an oversized name");
  const unknownTool = await request("tools/call", { name: diagnosticName, arguments: {} });
  assert(unknownTool.result?.isError === true, "unknown tool was accepted");
  assert(Buffer.byteLength(unknownTool.result.content[0].text) < 128, "unknown tool echoed an oversized name");
  const unknownResource = await request("resources/read", { uri: diagnosticName });
  assert(unknownResource.error?.code === -32602 && Buffer.byteLength(unknownResource.error.message) < 128,
    "unknown resource did not produce a bounded invalid-parameters error");
  for (const step of [{ tool: diagnosticName }, { tool: "spaceo_scroll", arguments: [] },
    { tool: "spaceo_scroll", argument: { dy: 10 } }]) {
    const invalidBatch = await request("tools/call", { name: "spaceo_run_steps", arguments: { steps: [step] } });
    assert(invalidBatch.result?.isError === true && Buffer.byteLength(invalidBatch.result.content[0].text) < 512,
      "malformed batch did not produce a bounded tool error");
  }
  const unexpectedKeys = await request("tools/call", {
    name: "spaceo_session_list",
    arguments: Object.fromEntries(Array.from({ length: 1_000 }, (_, i) => [`extra_${i}`, null])),
  });
  assert(unexpectedKeys.result?.isError === true, "unexpected fields were accepted");
  const diagnostic = unexpectedKeys.result.content[0].text;
  assert(Buffer.byteLength(diagnostic) <= 1_024 && diagnostic.includes("and 992 more"),
    "unexpected fields did not produce a bounded diagnostic with an omitted count");

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

  const schemaResult = spawnSync(binary, ["schema", "--json"], { encoding: "utf8", timeout: 5000 });
  assert(schemaResult.status === 0, "offline command schema failed");
  const schema = JSON.parse(schemaResult.stdout);
  assert(schema.schemaVersion === 1, "unknown command schema version");
  for (const command of [...Object.keys(schema.commands), "pool.set", "session", "daemon"]) {
    const help = spawnSync(binary, [...command.split("."), "--help", "--socket", `${socket}.absent`], { encoding: "utf8", timeout: 5000 });
    assert(help.status === 0 && help.stdout.includes("spaceo"), `offline help failed for ${command}`);
  }
  const jsonError = spawnSync(binary, ["drag", "--duration", "invalid", "--json"], { encoding: "utf8", timeout: 5000 });
  assert(jsonError.status !== 0 && JSON.parse(jsonError.stdout).errorCode, "CLI failure lost structured JSON");

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
  for (const line of diagnostics.split("\n")) {
    if (line.startsWith("[spaceo-mcp] tool ") || line.startsWith("[spaceo-mcp] tool.finished ")) {
      assert(Buffer.byteLength(line) <= 900, "tool diagnostics exceeded their byte budget");
    }
  }

  console.log(
    "MCP smoke passed: protocol, 34 tools, validation, mutation safety, and clean exit",
  );
} finally {
  if (!server.killed) server.kill("SIGTERM");
  spawnSync(binary, ["daemon", "stop", "--socket", socket], {
    stdio: "ignore",
    timeout: 5_000,
  });
  await waitForSocketRemoval();
  // The daemon leaves its startup lock behind on purpose (removing it would race a concurrent
  // starter); this throwaway socket has no other user, so the lock is ours to clean up.
  rmSync(`${socket}.lock`, { force: true });
}
