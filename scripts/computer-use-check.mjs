#!/usr/bin/env node
// Drive SpaceO through its real MCP stdio server, the way an agent client does.
//
// Every step is one tool call; nothing here reaches into the package. Where an action has an
// observable effect, the step asserts the effect rather than the call's return value — a tool
// that reports success and changes nothing is the failure this harness exists to catch.
//
// usage: node scripts/computer-use-check.mjs [path-to-spaceo]
//          [--suite=native|web|electron|all] [--require-full]
//          [--verify-display-cleanup] [--report=path.json]
//
// A suite whose host application is missing is recorded as SKIP, never as a pass: an unexercised
// capability is unknown, not working. Skips keep the run out of exit 0, and --require-full (for
// release-time runs) turns them into hard failures.

import { execFileSync, spawn } from "node:child_process";
import { createInterface } from "node:readline";
import {
  writeFileSync, readFileSync, existsSync, mkdirSync, statSync, chmodSync, mkdtempSync, rmSync,
} from "node:fs";
import { dirname, resolve, join } from "node:path";
import { createHash, randomUUID } from "node:crypto";
import { arch, platform, release, tmpdir } from "node:os";
import { toolResult, imagesChanged, isolationStatus } from "./computer-use-evidence.mjs";

const argv = process.argv.slice(2);
const binary = argv.find((a) => !a.startsWith("--")) ?? `${process.env.HOME}/.local/bin/spaceo`;
const suiteArg = (argv.find((a) => a.startsWith("--suite")) ?? "--suite=all").split("=")[1];
const suites = suiteArg === "all" ? ["native", "web", "electron"] : [suiteArg];
const requireFull = argv.includes("--require-full");
// Release conformance always proves that the virtual monitor goes away again and that the
// user's physical topology survived the run. Smaller development suites can opt into the same
// (slower) check explicitly.
const verifyDisplayCleanup = requireFull || argv.includes("--verify-display-cleanup");
const reportPath = (argv.find((a) => a.startsWith("--report=")) ?? "").split("=")[1]
  || process.env.SPACEO_TEST_REPORT;
const runID = process.env.SPACEO_RUN_ID || `cu-${randomUUID()}`;
const runStartedAt = new Date();
const runStartedMonotonic = performance.now();

if (process.env.SPACEO_LIVE_TESTS !== "1") {
  console.error("computer-use tests require SPACEO_LIVE_TESTS=1 on a reserved host; see docs/LIVE_TESTS.md");
  process.exit(1);
}

if (!suites.every((suite) => ["native", "web", "electron"].includes(suite))) {
  console.error(`unknown suite: ${suiteArg}`);
  process.exit(1);
}

// Overridable so the skip path itself is testable without uninstalling the host application.
const chromeApp = process.env.SPACEO_CU_CHROME_APP ?? "/Applications/Google Chrome.app";
const cursorApp = process.env.SPACEO_CU_CURSOR_APP ?? "/Applications/Cursor.app";

if (requireFull && suiteArg !== "all") {
  console.error(`--require-full demands the full matrix; --suite=${suiteArg} cannot satisfy it.`);
  process.exit(1);
}

const server = spawn(binary, ["mcp"], { stdio: ["pipe", "pipe", "pipe"] });
let diagnostics = "";
server.stderr.setEncoding("utf8");
server.stderr.on("data", (c) => { diagnostics = (diagnostics + c).slice(-1_048_576); });

const lines = [];
const waiters = [];
let transportFailure;
function stopWaiting(error) {
  transportFailure = error;
  for (const waiter of waiters.splice(0)) waiter.reject(error);
}
const serverClosed = new Promise((resolve) => {
  server.once("close", (code, signal) => {
    stopWaiting(new Error(`MCP exited (code ${code}, signal ${signal ?? "none"})`));
    resolve();
  });
});
server.on("error", (error) => stopWaiting(error));
server.stdin.on("error", (error) => stopWaiting(error));
createInterface({ input: server.stdout }).on("line", (line) => {
  const waiter = waiters.shift();
  if (waiter) waiter.resolve(line); else lines.push(line);
});

function nextLine(timeout = 140_000) {
  if (lines.length) return Promise.resolve(lines.shift());
  if (transportFailure) return Promise.reject(transportFailure);
  return new Promise((resolve, reject) => {
    const waiter = {
      resolve: (line) => { clearTimeout(timer); resolve(line); },
      reject: (error) => { clearTimeout(timer); reject(error); },
    };
    const timer = setTimeout(() => {
      const index = waiters.indexOf(waiter);
      if (index >= 0) waiters.splice(index, 1);
      reject(new Error("MCP response timed out"));
    }, timeout);
    waiters.push(waiter);
  });
}

let id = 1;
const toolCalls = [];
async function rpc(method, params = {}) {
  server.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: id++, method, params })}\n`);
  return JSON.parse(await nextLine());
}

async function call(name, args = {}) {
  const started = performance.now();
  try {
    const r = await rpc("tools/call", { name, arguments: args });
    const result = toolResult(r);
    toolCalls.push({
      tool: name,
      ms: Math.round(performance.now() - started),
      ok: result.ok,
      unconfirmed: result.unconfirmed,
    });
    return result;
  } catch (error) {
    toolCalls.push({
      tool: name,
      ms: Math.round(performance.now() - started),
      ok: false,
      unconfirmed: false,
      transportError: true,
    });
    throw error;
  }
}

const results = [];
// A passing step keeps its one-line summary; anything that needs action (FAIL, BLOCK, SKIP)
// prints its detail in full. Multi-line errors — a TeardownReport naming the exact surviving
// process, a scroll rejection explaining the coordinate space — put the remedy after the first
// newline, and truncating them turns a diagnosable failure into "re-run and hope".
function detailLines(detail, full) {
  const text = String(detail);
  if (!text) return "";
  const lines = full ? text.split("\n") : [text.split("\n")[0].slice(0, 150)];
  return `\n${lines.map((l) => `        ${l}`).join("\n")}`;
}
class QualificationStopped extends Error {}
function recordStep(label, ok, detail = "") {
  results.push({
    label,
    status: ok ? "pass" : "fail",
    atMs: Math.round(performance.now() - runStartedMonotonic),
  });
  console.log(`${ok ? "PASS" : "FAIL"}  ${label}${detailLines(detail, !ok)}`);
}
function step(label, ok, detail = "") {
  recordStep(label, ok, detail);
  if (!ok) throw new QualificationStopped(label);
}
function blocked(label, detail = "") {
  results.push({
    label,
    status: "blocked",
    atMs: Math.round(performance.now() - runStartedMonotonic),
  });
  console.log(`BLOCK ${label}${detailLines(detail, true)}`);
  throw new QualificationStopped(label);
}
/// A capability that was never exercised. Deliberately not a pass: it contributes to no pass
/// count and keeps the run out of exit 0.
function skipped(label, detail = "") {
  results.push({
    label,
    status: "skipped",
    atMs: Math.round(performance.now() - runStartedMonotonic),
  });
  console.log(`SKIP  ${label}${detailLines(detail, true)}`);
}
function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }

function cliJSON(args) {
  const output = execFileSync(binary, args, {
    encoding: "utf8",
    maxBuffer: 1024 * 1024,
    // Display retirement can occupy the daemon for its own 10-second removal budget.
    // Leave bounded response headroom instead of killing the CLI at that exact boundary.
    timeout: 15_000,
  });
  return JSON.parse(output);
}

function userDisplayTopology(doctor) {
  const displays = doctor?.displays ?? {};
  const sorted = (value) => [...(value ?? [])].map(Number).sort((a, b) => a - b);
  return {
    userOnline: sorted(displays.userOnline),
    userActive: sorted(displays.userActive),
    mirroredUser: sorted(displays.mirroredUser),
  };
}

async function waitForIdlePool(timeoutMs = 22_000) {
  const deadline = Date.now() + timeoutMs;
  let pool;
  do {
    pool = cliJSON(["pool", "--operator", "--json"]);
    if (pool?.usage?.sessions === 0 && pool?.usage?.displays === 0) return pool;
    await sleep(250);
  } while (Date.now() < deadline);
  return pool;
}

function assertWindowsContained(label, listing) {
  const count = (listing.text.match(/^\s*window \d+/gm) ?? []).length;
  const outside = /\[outside this session's tile\]/.test(listing.text);
  step(label, listing.ok && count > 0 && !outside,
       outside ? listing.text : `${count} published window(s), all contained`);
}

// ---------------------------------------------------------------- fixtures

const fixtureRoot = mkdtempSync(join(tmpdir(), "spaceo-cu-"));
const textFixture = join(fixtureRoot, "spaceo-cu-native.txt");
const doc = Array.from({ length: 200 }, (_, i) => `line ${i + 1}: the quick brown fox`);
doc[179] = "line 180: TARGET-BELOW-THE-FOLD";
writeFileSync(textFixture, `${doc.join("\n")}\n`);

// A page exercising every action with a visible, readable result.
const pageFixture = join(fixtureRoot, "spaceo-cu-page.html");
writeFileSync(pageFixture, `<!doctype html><meta charset="utf-8"><title>SpaceO CU</title>
<style>
 body{font:16px system-ui;margin:0}
 #pad{padding:16px}
 #hover{padding:12px;background:#eee;width:200px}#hover:hover{background:#0a0;color:#fff}
 #target{margin-top:2200px;padding:12px;background:#fd0}
 button{padding:10px 14px;font-size:16px}
 input{padding:8px;font-size:16px}
 select{font-size:16px;vertical-align:top}
 #context{display:inline-block;padding:10px 14px;background:#def;border:1px solid #69c}
</style>
<div id=pad>
 <button id=btn>CLICK ME</button>
 <div id=hover>HOVER ME</div>
 <input id=field placeholder="type here">
 <input id=slider type=range min=0 max=100 value=20 aria-label="Slider">
 <select id=multi multiple size=2 aria-label="Multi-select">
  <option>Alpha</option><option>Beta</option>
 </select>
 <div id=context role=button tabindex=0>CONTEXT MENU</div>
 <div id=target>TARGET-BELOW-THE-FOLD</div>
</div>
<script>
 // The window title is the only page state an agent can observe through the tools, so every
 // event is encoded there. That makes each web step assert its *effect*, not its return value.
 const ev = new Set();
 const render = () =>
   document.title = "CU ev=" + ([...ev].join("+") || "none") + " y=" + Math.round(scrollY);
 const log = (m) => { ev.add(m); render(); };
 btn.onclick = () => log('click');
 btn.onauxclick = (e) => { if (e.button === 1) log('middle'); };
 hover.onmouseenter = () => log('hover');
 field.oninput = () => log('input');
 slider.oninput = () => log('slider');
 multi.onchange = () => { if (multi.selectedOptions.length >= 2) log('multi'); };
 context.oncontextmenu = (e) => { e.preventDefault(); log('context'); };
 addEventListener('mouseup', () => { if (getSelection().toString()) log('drag'); });
 addEventListener('scroll', render, { passive: true });
 render();
</script>`);

// A synthetic Electron bundle exercises refusal even when Cursor is not installed.
const electronFixture = join(fixtureRoot, "Refused Electron.app");
mkdirSync(join(electronFixture, "Contents/Frameworks/Electron Framework.framework"),
          { recursive: true });

// ---------------------------------------------------------------- helpers

async function newSession(name) {
  const created = await call("spaceo_session_create", { name });
  if (!created.ok) throw new Error(`session create failed: ${created.text}`);
  return name;
}

async function destroy(session) {
  const d = await call("spaceo_session_destroy", { session });
  step(`[${session}] destroy`, d.ok, d.text);
}

/// The web fixture encodes its state in the window title, which is the only page state the tool
/// surface exposes. Reading it back is how a web step proves its action had an effect.
async function pageState(session) {
  const windows = await call("spaceo_list_windows", { session });
  const match = windows.text.match(/CU ev=([\w+]+) y=(\d+)/);
  if (!match) return { events: [], scrollY: 0, raw: windows.text };
  return {
    events: match[1] === "none" ? [] : match[1].split("+"),
    scrollY: Number(match[2]),
    raw: match[0],
  };
}

function pointFor(listing, label) {
  // Native AX controls and DevTools page elements can share the same label. Only the wN rows
  // publish CSS viewport coordinates; accepting the first labelled AX row makes a healthy page
  // look coordinate-less whenever Chrome also exposes that control through accessibility.
  const line = listing.text.split("\n").find((candidate) =>
    /^\s*\[w\d+\]/.test(candidate) && candidate.includes(`— ${label}`));
  const match = line?.match(/at \((\d+),(\d+)\)/);
  return match ? { x: Number(match[1]), y: Number(match[2]) } : null;
}

// ---------------------------------------------------------------- suites

async function verifyIsolation(session, label) {
  const result = await call("spaceo_verify_isolation", { session });
  const status = isolationStatus(result);
  if (status === "blocked") blocked(`[${label}] isolation coverage is incomplete`, result.text);
  else step(`[${label}] isolation checks are intact`, status === "pass", result.text);
}

async function nativeSuite() {
  const s = await newSession("cu-native");
  try {
    const opened = await call("spaceo_open_app",
      { session: s, app: "TextEdit", files: [textFixture] });
    step("[native] launch TextEdit onto the agent display", opened.ok, opened.text);
    if (!opened.ok) throw new Error(`native launch failed: ${opened.text}`);
    await sleep(2000);

    const windows = await call("spaceo_list_windows", { session: s });
    const docWindow = Number((windows.text.match(/window (\d+)[^\n]*spaceo-cu-native/) ?? [])[1]);
    step("[native] the document window is identifiable", Boolean(docWindow), `window ${docWindow}`);
    assertWindowsContained("[native] every published window is contained on the agent display",
                           windows);

    const shot = await call("spaceo_screenshot", { session: s, window: docWindow });
    step("[native] screenshot states pixels are click coordinates",
         shot.ok && /pixels are window-local points/.test(shot.text), shot.text);

    // Scroll has to actually move content, not merely return success.
    const before = await call("spaceo_screenshot", { session: s, window: docWindow });
    const scrolled = await call("spaceo_scroll",
      { session: s, window: docWindow, x: 400, y: 400, dy: -1200, ticks: 3 });
    await sleep(700);
    const after = await call("spaceo_screenshot", { session: s, window: docWindow });
    step("[native] scroll moves the document",
         scrolled.ok && !scrolled.unconfirmed && imagesChanged(before, after),
         scrolled.ok ? "pixels changed" : scrolled.text);

    // A long document's text is clipped by the traversal's per-value byte cap, so the marker is
    // deliberately *not* expected here. What must not happen is silent clipping: a partial read
    // that looks complete is how an agent concludes content does not exist.
    const read = await call("spaceo_read_screen", { session: s, window: docWindow, full: true });
    const clipped = /…/.test(read.text);
    step("[native] a clipped screen read discloses that it was clipped",
         read.ok && (!clipped || /clipped/.test(read.text)),
         clipped ? "clipping disclosed in the message" : "nothing was clipped");

    // A coordinate click into a text area has no pressable element under it, so it must be
    // reported as unconfirmed rather than as a plain success.
    const blindClick = await call("spaceo_click",
      { session: s, window: docWindow, x: 300, y: 300 });
    step("[native] unconfirmable click says so", blindClick.unconfirmed,
         blindClick.unconfirmed ? "reported UNCONFIRMED" : "silently reported success");

    // The value `spaceo_type` returns is read back the instant the last key is posted, so a
    // slow app can still be mid-insert — an observed run came back holding just "N" of
    // "NATIVE-OK ". That is the assertion racing the app, not the keystrokes failing to land,
    // so re-read until the text appears. A step that fails one run in ten teaches people to
    // re-run the suite instead of reading it.
    const typed = await call("spaceo_type", { session: s, window: docWindow, text: "NATIVE-OK " });
    let typedText = typed.text;
    for (let attempt = 0; attempt < 10 && !/NATIVE-OK/.test(typedText); attempt += 1) {
      await sleep(200);
      typedText = (await call("spaceo_read_screen",
        { session: s, window: docWindow, full: true })).text;
    }
    step("[native] type reaches the document",
         typed.ok && /NATIVE-OK/.test(typedText), typedText.split("\n")[0]);
    await verifyIsolation(s, "native");
  } finally {
    await destroy("cu-native");
  }
}

async function webSuite() {
  if (!existsSync(chromeApp)) {
    skipped("[web] whole suite: the DevTools bridge went unexercised",
            `Google Chrome is not installed at ${chromeApp}`);
    return;
  }
  const s = await newSession("cu-web");
  try {
    const opened = await call("spaceo_open_app",
      { session: s, app: "Google Chrome", files: [pageFixture] });
    step("[web] launch Chrome with a DevTools port", opened.ok, opened.text);
    if (!opened.ok) throw new Error(`web launch failed: ${opened.text}`);
    await sleep(5000);

    const read = await call("spaceo_read_screen", { session: s });
    const hasPage = /\[w\d+\]/.test(read.text);
    step("[web] page elements appear under wN references", read.ok && hasPage,
         hasPage ? "DevTools bridge attached" : read.text);

    const launchWindows = await call("spaceo_list_windows", { session: s });
    assertWindowsContained("[web] every published window is contained on the agent display",
                           launchWindows);

    const clicked = await call("spaceo_click", { session: s, element: "w0" });
    await sleep(500);
    let state = await pageState(s);
    step("[web] click a page element by reference fires a DOM click",
         clicked.ok && state.events.includes("click"), state.raw);

    // Each of these is impossible without a DevTools implementation: synthetic events never
    // reach web content, and a page scroller is not an accessibility scroll bar either.
    const scrolled = await call("spaceo_scroll",
      { session: s, x: 400, y: 300, dy: -1500, ticks: 3 });
    await sleep(900);
    state = await pageState(s);
    step("[web] scroll actually moves the page",
         scrolled.ok && !scrolled.unconfirmed && state.scrollY > 500,
         `${state.raw} (scrollY must exceed 500)`);

    // Back to the top, then drive by the CSS viewport coordinates read_screen prints beside
    // each wN element — which is the only positional information an agent has for a page.
    await call("spaceo_scroll", { session: s, x: 400, y: 300, dy: 5000, ticks: 3, web: true });
    await sleep(700);

    const listing = await call("spaceo_read_screen", { session: s });
    const button = listing.text.match(/\[w0\][^\n]*at \((\d+),(\d+)\)/);
    step("[web] page elements carry usable coordinates", Boolean(button),
         button ? `w0 at (${button[1]},${button[2]})` : listing.text);

    // The hover target sits just below the button in the fixture.
    const hx = Number(button?.[1] ?? 70);
    const hy = Number(button?.[2] ?? 37) + 45;
    const hoverTarget = await call("spaceo_move", { session: s, x: hx, y: hy, web: true });
    await sleep(500);
    state = await pageState(s);
    step("[web] hover at viewport coordinates fires mouseenter",
         hoverTarget.ok && state.events.includes("hover"), state.raw);

    const dragged = await call("spaceo_drag",
      { session: s, x: hx - 40, y: hy, to_x: hx + 120, to_y: hy, web: true });
    await sleep(600);
    state = await pageState(s);
    step("[web] drag selects text in the page", dragged.ok && state.events.includes("drag"), state.raw);

    await call("spaceo_click", { session: s, element: "w1" });
    const typed = await call("spaceo_type", { session: s, text: "WEB-OK", web: true });
    await sleep(500);
    state = await pageState(s);
    step("[web] type reaches a page input field",
         typed.ok && state.events.includes("input"), state.raw);

    const slider = pointFor(listing, "Slider");
    step("[web] slider exposes usable viewport coordinates", Boolean(slider), listing.text);
    if (slider) {
      const draggedSlider = await call("spaceo_drag", {
        session: s,
        x: slider.x - 35,
        y: slider.y,
        to_x: slider.x + 35,
        to_y: slider.y,
        web: true,
      });
      await sleep(500);
      state = await pageState(s);
      step("[web] dragging a slider changes its value",
           draggedSlider.ok && state.events.includes("slider"), state.raw);
    }

    const multi = pointFor(listing, "Multi-select");
    step("[web] multi-select exposes usable viewport coordinates", Boolean(multi), listing.text);
    if (multi) {
      await call("spaceo_click", {
        session: s, x: multi.x, y: multi.y - 9, web: true,
      });
      const extended = await call("spaceo_click", {
        session: s,
        x: multi.x,
        y: multi.y + 9,
        modifiers: ["cmd"],
        web: true,
      });
      await sleep(500);
      state = await pageState(s);
      step("[web] modifier-click extends a multi-select selection",
           extended.ok && state.events.includes("multi"), state.raw);
    }

    const context = pointFor(listing, "CONTEXT MENU");
    step("[web] context target exposes usable viewport coordinates", Boolean(context), listing.text);
    if (context) {
      const openedContext = await call("spaceo_click", {
        session: s,
        x: context.x,
        y: context.y,
        button: "right",
        web: true,
      });
      await sleep(500);
      state = await pageState(s);
      step("[web] right-click opens the page context action",
           openedContext.ok && state.events.includes("context"), state.raw);
    }
    await verifyIsolation(s, "web");
  } finally {
    await destroy("cu-web");
  }
}

async function electronSuite() {
  const s = await newSession("cu-electron");
  try {
    const opened = await call("spaceo_open_app", {
      session: s, app: existsSync(cursorApp) ? cursorApp : electronFixture,
    });
    step("[electron] preview refuses managed launch before app startup",
         !opened.ok && /unsupported_target/.test(opened.text)
         && /managed Electron launches are unavailable/.test(opened.text), opened.text);
    const windows = await call("spaceo_list_windows", { session: s });
    step("[electron] refused launch publishes no windows",
         windows.ok && !/window \d+/.test(windows.text), windows.text);
  } finally {
    await destroy("cu-electron");
  }
}

// ---------------------------------------------------------------- run

try {
  const init = await rpc("initialize", {
    protocolVersion: "2025-11-25",
    capabilities: {},
    clientInfo: { name: "computer-use-check", version: "1" },
  });
  step("initialize", init.result?.protocolVersion === "2025-11-25");

  const listed = await rpc("tools/list");
  const names = (listed.result?.tools ?? []).map((t) => t.name);
  step(`tools/list advertises ${names.length} tools`,
       names.length === 34 && new Set(names).size === names.length);

  let displayBaseline;
  if (verifyDisplayCleanup) {
    const cleanStart = await waitForIdlePool();
    if (cleanStart?.usage?.sessions !== 0 || cleanStart?.usage?.displays !== 0) {
      throw new Error("display-safety preflight requires an idle daemon with no sessions or displays");
    }
    displayBaseline = userDisplayTopology(cliJSON(["doctor", "--json"]));
  }

  const suiteRunners = { native: nativeSuite, web: webSuite, electron: electronSuite };
  for (const suite of suites) {
    try {
      await suiteRunners[suite]();
    } catch (error) {
      // Each suite tears down its own session in finally. Do not launch more applications or
      // attach another display after the first failed assertion, blocked result or RPC error.
      if (!(error instanceof QualificationStopped)) recordStep(`[${suite}] suite error`, false, error.message);
      break;
    }
  }

  if (verifyDisplayCleanup) {
    const idle = await waitForIdlePool();
    step("[cleanup] the idle pool retires every virtual display",
         idle?.usage?.sessions === 0 && idle?.usage?.displays === 0,
         idle?.message ?? JSON.stringify(idle));

    const doctor = cliJSON(["doctor", "--json"]);
    const after = userDisplayTopology(doctor);
    const topologyUnchanged = JSON.stringify(after) === JSON.stringify(displayBaseline);
    const noSpaceO = (doctor?.displays?.spaceO ?? []).length === 0;
    const noOrphans = (doctor?.displays?.orphanedSpaceO ?? []).length === 0;
    step("[cleanup] the user's display topology is unchanged",
         topologyUnchanged && noSpaceO && noOrphans,
         topologyUnchanged
           ? `online ${after.userOnline.join(",")}; active ${after.userActive.join(",")}`
           : `before ${JSON.stringify(displayBaseline)}; after ${JSON.stringify(after)}`);
  }
} catch (error) {
  if (!(error instanceof QualificationStopped)) recordStep("harness error", false, error.message);
} finally {
  server.stdin.end();
  // Register close handling at spawn time: a child that already exited must not hang cleanup.
  // Terminate only this harness's MCP subprocess; the shared daemon keeps its normal ownership.
  let shutdownTimedOut = false;
  const shutdownTimer = setTimeout(() => {
    shutdownTimedOut = true;
    server.kill("SIGTERM");
  }, 5_000);
  const killTimer = setTimeout(() => server.kill("SIGKILL"), 8_000);
  await serverClosed;
  clearTimeout(shutdownTimer);
  clearTimeout(killTimer);
  if (shutdownTimedOut || server.exitCode !== 0) {
    recordStep("MCP shutdown", false, "MCP did not exit cleanly after input closed");
  }
  try { rmSync(fixtureRoot, { recursive: true, force: true }); } catch {}
  const failed = results.filter((r) => r.status === "fail");
  const blockers = results.filter((r) => r.status === "blocked");
  const skips = results.filter((r) => r.status === "skipped");
  const passed = results.filter((r) => r.status === "pass");
  const exercised = results.length - skips.length;
  const parityPercent = exercised ? Math.round((passed.length / exercised) * 1000) / 10 : 0;
  console.log(`\nComputer-use parity: ${passed.length}/${exercised} (${parityPercent}%) exercised steps passed`
    + `${blockers.length ? `; ${blockers.length} blocked` : ""}`
    + `${skips.length ? `; ${skips.length} SKIPPED — this run is NOT a conformance pass` : ""}`);
  if (failed.length) console.log(`failed:\n  ${failed.map((f) => f.label).join("\n  ")}`);
  if (blockers.length) {
    console.log(`blocked:\n  ${blockers.map((b) => b.label).join("\n  ")}`);
  }
  if (skips.length) {
    console.log(`skipped (capability unknown, not working):\n  `
      + skips.map((s) => s.label).join("\n  "));
    if (requireFull) console.log("--require-full was passed, so a skip is a failure.");
  }
  if (diagnostics.trim()) console.log(`\nserver stderr:\n${diagnostics.trim()}`);
  let reportFailure = false;
  if (reportPath) {
    try {
      const binaryBytes = readFileSync(binary);
      const report = {
        schemaVersion: 1,
        runID,
        startedAt: runStartedAt.toISOString(),
        finishedAt: new Date().toISOString(),
        durationMs: Math.round(performance.now() - runStartedMonotonic),
        host: { platform: platform(), release: release(), arch: arch() },
        binary: {
          path: resolve(binary),
          bytes: statSync(binary).size,
          sha256: createHash("sha256").update(binaryBytes).digest("hex"),
        },
        configuration: { suite: suiteArg, requireFull, verifyDisplayCleanup },
        summary: {
          passed: passed.length,
          failed: failed.length,
          blocked: blockers.length,
          skipped: skips.length,
          parityPercent,
          toolCalls: toolCalls.length,
          mcpDiagnosticBytes: Buffer.byteLength(diagnostics),
        },
        // Labels and timing are deliberately retained; raw tool text, typed payloads, leases,
        // screenshots, and accessibility content are deliberately absent.
        steps: results,
        tools: toolCalls,
      };
      mkdirSync(dirname(reportPath), { recursive: true });
      writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`, { mode: 0o600 });
      chmodSync(reportPath, 0o600);
      console.log(`structured report: ${reportPath} (run ${runID})`);
    } catch (error) {
      reportFailure = true;
      console.error(`could not write structured report ${reportPath}: ${error.message}`);
    }
  }
  const hardFail = failed.length || (requireFull && skips.length) || reportFailure;
  process.exit(hardFail ? 1 : blockers.length || skips.length ? 2 : 0);
}
