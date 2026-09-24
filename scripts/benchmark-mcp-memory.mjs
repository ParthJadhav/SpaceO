#!/usr/bin/env node
// Real MCP request loop with a synthetic ping-only socket. No daemon or GUI work.
// node scripts/benchmark-mcp-memory.mjs /path/to/spaceo [request-count]
import { spawn, execFileSync } from "node:child_process";
import { createServer } from "node:net";
import { createInterface } from "node:readline";
import { once } from "node:events";
import { rmSync } from "node:fs";
import { resolve } from "node:path";

const binary = resolve(process.argv[2] ?? ".build/release/spaceo");
const count = Number(process.argv[3] ?? 1000);
if (!Number.isInteger(count) || count < 100 || count > 10000) throw new Error("count must be 100...10000");
const path = `/tmp/spaceo-memory-bench-${process.pid}.sock`;
const peer = createServer((socket) => {
  socket.once("data", () => socket.end('{"ok":true}\n'));
});
await new Promise((resolveListen, reject) => {
  peer.once("error", reject);
  peer.listen(path, resolveListen);
});
const child = spawn(binary, ["mcp", "--socket", path], { stdio: ["pipe", "pipe", "ignore"] });
const exited = once(child, "exit");
const reader = createInterface({ input: child.stdout });
const lines = reader[Symbol.asyncIterator]();
const timer = setTimeout(() => child.kill("SIGKILL"), 60000);
const samples = [];
let bytes = 0;
const start = performance.now();
try {
  for (let i = 1; i <= count; i++) {
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: i, method: "tools/list" }) + "\n");
    const { value, done } = await lines.next();
    if (done) throw new Error("MCP exited before returning every result");
    const reply = JSON.parse(value);
    if (reply.id !== i || reply.result?.tools?.length !== 32) throw new Error("invalid MCP response");
    bytes += Buffer.byteLength(value);
    if (i === 50 || i === 100 || i === Math.floor(count / 2) || i === count) {
      const rssKiB = Number(execFileSync("ps", ["-o", "rss=", "-p", String(child.pid)], { encoding: "utf8" }).trim());
      samples.push({ requests: i, rssKiB });
    }
  }
  child.stdin.end();
  const [code, signal] = await exited;
  if (code !== 0) throw new Error(`MCP exited ${code}/${signal}`);
  console.log(JSON.stringify({ binary, count, bytes, milliseconds: performance.now() - start, samples }));
} finally {
  clearTimeout(timer);
  if (child.exitCode === null && child.signalCode === null) {
    child.kill("SIGKILL");
    await exited;
  }
  reader.close();
  await new Promise((resolveClose) => peer.close(resolveClose));
  rmSync(path, { force: true });
}
