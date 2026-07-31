#!/usr/bin/env node
// Drive SpaceO through its real MCP stdio server, the way an agent client does.
//
// Every step is one tool call; nothing here reaches into the package. Where an action has an
// observable effect, the step asserts the effect rather than the call's return value — a tool
// that reports success and changes nothing is the failure this harness exists to catch.
//
// usage: node scripts/computer-use-check.mjs [path-to-spaceo] [--suite=native|web|electron|all]

import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { writeFileSync, existsSync } from "node:fs";

const argv = process.argv.slice(2);
const binary = argv.find((a) => !a.startsWith("--")) ?? `${process.env.HOME}/.local/bin/spaceo`;
const suiteArg = (argv.find((a) => a.startsWith("--suite")) ?? "--suite=all").split("=")[1];
const suites = suiteArg === "all" ? ["native", "web", "electron"] : [suiteArg];

const server = spawn(binary, ["mcp"], { stdio: ["pipe", "pipe", "pipe"] });
let diagnostics = "";
server.stderr.setEncoding("utf8");
server.stderr.on("data", (c) => { diagnostics += c; });

const lines = [];
const waiters = [];
createInterface({ input: server.stdout }).on("line", (line) => {
  const w = waiters.shift();
  if (w) w(line); else lines.push(line);
});

function nextLine(timeout = 140_000) {
  if (lines.length) return Promise.resolve(lines.shift());
  return new Promise((res, rej) => {
    const t = setTimeout(() => rej(new Error(`timeout. stderr:\n${diagnostics}`)), timeout);
    waiters.push((l) => { clearTimeout(t); res(l); });
  });
}

let id = 1;
async function rpc(method, params = {}) {
  server.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: id++, method, params })}\n`);
  return JSON.parse(await nextLine());
}

async function call(name, args = {}) {
  const r = await rpc("tools/call", { name, arguments: args });
  const content = r.result?.content ?? [];
  const text = content.filter((c) => c.type === "text").map((c) => c.text).join("\n");
  const image = content.find((c) => c.type === "image")?.data ?? null;
  return {
    ok: r.result?.isError !== true,
    text,
    image,
    unconfirmed: /UNCONFIRMED:/.test(text),
  };
}

const results = [];
function step(label, ok, detail = "") {
  results.push({ label, status: ok ? "pass" : "fail" });
  const line = String(detail).split("\n")[0].slice(0, 150);
  console.log(`${ok ? "PASS" : "FAIL"}  ${label}${line ? `\n        ${line}` : ""}`);
}
function blocked(label, detail = "") {
  results.push({ label, status: "blocked" });
  const line = String(detail).split("\n")[0].slice(0, 150);
  console.log(`BLOCK ${label}${line ? `\n        ${line}` : ""}`);
}
function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }

// ---------------------------------------------------------------- fixtures

const textFixture = "/tmp/spaceo-cu-native.txt";
const doc = Array.from({ length: 200 }, (_, i) => `line ${i + 1}: the quick brown fox`);
doc[179] = "line 180: TARGET-BELOW-THE-FOLD";
writeFileSync(textFixture, `${doc.join("\n")}\n`);

// A page exercising every action with a visible, readable result.
const pageFixture = "/tmp/spaceo-cu-page.html";
writeFileSync(pageFixture, `<!doctype html><meta charset="utf-8"><title>SpaceO CU</title>
<style>
 body{font:16px system-ui;margin:0}
 #pad{padding:16px}
 #hover{padding:12px;background:#eee;width:200px}#hover:hover{background:#0a0;color:#fff}
 #target{margin-top:2200px;padding:12px;background:#fd0}
 button{padding:10px 14px;font-size:16px}
 input{padding:8px;font-size:16px}
</style>
<div id=pad>
 <button id=btn>CLICK ME</button>
 <div id=hover>HOVER ME</div>
 <input id=field placeholder="type here">
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
 addEventListener('mouseup', () => { if (getSelection().toString()) log('drag'); });
 addEventListener('scroll', render, { passive: true });
 render();
</script>`);

const electronFixture = "/tmp/spaceo-cu-electron.txt";
writeFileSync(
  electronFixture,
  `${Array.from({ length: 400 }, (_, i) =>
    `electron line ${i + 1}: ${i === 349 ? "ELECTRON-TARGET-BELOW-THE-FOLD" : "the quick brown fox"}`
  ).join("\n")}\n`,
);

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

// ---------------------------------------------------------------- suites

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
         scrolled.ok && before.image !== after.image,
         scrolled.ok ? "pixels changed" : scrolled.text);

    // A long document's text is clipped by the traversal's per-value byte cap, so the marker is
    // deliberately *not* expected here. What must not happen is silent clipping: a partial read
    // that looks complete is how an agent concludes content does not exist.
    const read = await call("spaceo_read_screen", { session: s, window: docWindow, full: true });
    const clipped = /…/.test(read.text);
    step("[native] a clipped screen read discloses that it was clipped",
         !clipped || /clipped/.test(read.text),
         clipped ? "clipping disclosed in the message" : "nothing was clipped");

    // A coordinate click into a text area has no pressable element under it, so it must be
    // reported as unconfirmed rather than as a plain success.
    const blindClick = await call("spaceo_click",
      { session: s, window: docWindow, x: 300, y: 300 });
    step("[native] unconfirmable click says so", blindClick.unconfirmed,
         blindClick.unconfirmed ? "reported UNCONFIRMED" : "silently reported success");

    const typed = await call("spaceo_type", { session: s, window: docWindow, text: "NATIVE-OK " });
    step("[native] type reaches the document",
         typed.ok && /NATIVE-OK/.test(typed.text), typed.text);
  } finally {
    await destroy("cu-native");
  }
}

async function webSuite() {
  if (!existsSync("/Applications/Google Chrome.app")) {
    step("[web] skipped: Google Chrome is not installed", true);
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
    step("[web] page elements appear under wN references", hasPage,
         hasPage ? "DevTools bridge attached" : read.text);

    await call("spaceo_click", { session: s, element: "w0" });
    await sleep(500);
    let state = await pageState(s);
    step("[web] click a page element by reference fires a DOM click",
         state.events.includes("click"), state.raw);

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

    await call("spaceo_drag",
      { session: s, x: hx - 40, y: hy, to_x: hx + 120, to_y: hy, web: true });
    await sleep(600);
    state = await pageState(s);
    step("[web] drag selects text in the page", state.events.includes("drag"), state.raw);

    await call("spaceo_click", { session: s, element: "w1" });
    await call("spaceo_type", { session: s, text: "WEB-OK", web: true });
    await sleep(500);
    state = await pageState(s);
    step("[web] type reaches a page input field",
         state.events.includes("input"), state.raw);
  } finally {
    await destroy("cu-web");
  }
}

async function electronSuite() {
  if (!existsSync("/Applications/Cursor.app")) {
    step("[electron] skipped: Cursor is not installed", true);
    return;
  }
  const s = await newSession("cu-electron");
  try {
    const opened = await call(
      "spaceo_open_app",
      { session: s, app: "Cursor", files: [electronFixture] },
    );
    step("[electron] launch Cursor onto the agent display", opened.ok, opened.text);
    if (!opened.ok) throw new Error(`Electron launch failed: ${opened.text}`);
    await sleep(7000);

    const read = await call("spaceo_read_screen", { session: s, full: true });
    step("[electron] accessibility tree is readable", read.ok && read.text.length > 40,
         `${read.text.split("\n").length} outline lines`);

    const shot = await call("spaceo_screenshot", { session: s });
    step("[electron] window renders on the virtual display",
         shot.ok && /rendered=true/.test(shot.text), shot.text);

    // Cursor's editor is renderer content. A successful return is not evidence; compare the
    // rendered window before and after the wheel event. Until Electron has a private CDP
    // endpoint this is a release blocker, not a passing "honest refusal": the product cannot
    // claim pointer parity merely because it admitted that the action had no effect.
    const before = await call("spaceo_screenshot", { session: s });
    const scrolled = await call("spaceo_scroll",
      { session: s, x: 500, y: 400, dy: -1600, ticks: 4, web: true });
    await sleep(900);
    const after = await call("spaceo_screenshot", { session: s });
    const electronControlled =
      scrolled.ok && !scrolled.unconfirmed && before.image !== after.image;
    if (electronControlled) {
      step("[electron] pointer scroll changes renderer pixels", true,
           "confirmed by a before/after screenshot difference");
    } else {
      blocked("[electron] pointer scroll has no safe renderer channel (SPAO-179)",
              scrolled.ok ? "no observable renderer effect" : scrolled.text);
    }

    const isolation = await call("spaceo_verify_isolation", { session: s });
    step("[electron] self-activating app did not breach isolation",
         isolation.ok && !/ISOLATION BREACH/.test(isolation.text),
         (isolation.text.match(/isolation: \w+[^\n]*/) ?? [""])[0]);
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
  step(`tools/list advertises ${names.length} tools`, names.length === 16);

  if (suites.includes("native")) await nativeSuite();
  if (suites.includes("web")) await webSuite();
  if (suites.includes("electron")) await electronSuite();
} catch (error) {
  step(`harness error: ${error.message}`, false);
} finally {
  server.stdin.end();
  await new Promise((r) => server.once("exit", r));
  const failed = results.filter((r) => r.status === "fail");
  const blockers = results.filter((r) => r.status === "blocked");
  const passed = results.filter((r) => r.status === "pass");
  console.log(`\n${passed.length}/${results.length} steps passed`
    + `${blockers.length ? `; ${blockers.length} blocked` : ""}`);
  if (failed.length) console.log(`failed:\n  ${failed.map((f) => f.label).join("\n  ")}`);
  if (blockers.length) {
    console.log(`blocked:\n  ${blockers.map((b) => b.label).join("\n  ")}`);
  }
  if (diagnostics.trim()) console.log(`\nserver stderr:\n${diagnostics.trim()}`);
  process.exit(failed.length ? 1 : blockers.length ? 2 : 0);
}
