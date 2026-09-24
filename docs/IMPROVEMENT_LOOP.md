# Improvement loop: local logging and the journal report

SpaceO can record every agent tool call and every daemon request on this Mac. With those
records you can see, from real use, where agents lose time, tokens and calls, and why. Then you
can fix the top item and check whether it moved.

Everything stays local: files are owner-only (0600), bounded in size and age, and never uploaded.

## Turn it on

```bash
spaceo logging enable            # full journal + every daemon request (default)
spaceo logging enable --level metadata --retention-days 30 --max-mb 100
spaceo logging status
spaceo logging disable           # back to failures-only; existing files age out
```

Changes apply within five seconds to a running daemon and to running MCP servers from 1.1.1 on.
Older MCP servers need their client restarted. For a single run you can override the settings
file with environment variables: `SPACEO_JOURNAL=off|metadata|full` and `SPACEO_LOG_METRICS=1`.
`SPACEO_RUN_ID=<name>` tags daemon records so you can compare runs.

| What | Where | Written by |
|---|---|---|
| Settings | `~/Library/Application Support/SpaceO/logging.json` | `spaceo logging` |
| Agent journal | `~/Library/Logs/SpaceO/journal/<yyyy-MM-dd>/mcp-<pid>-<conn>.jsonl` | each MCP server (one file per connection) |
| Daemon log | `~/Library/Logs/SpaceO/daemon.log` (+ `.1`) | the daemon: CLI, Viewer and MCP requests |

`spaceo doctor` shows the current state in its **Logging** section.

## What is recorded

**Agent journal** (one JSON line per event, schema `v: 1`):

- `connection.start` records the MCP client's name and version, the protocol version, and the
  app macOS attributes permissions to. `connection.end` records the reason, the call count and
  the count of each outcome.
- `tool_call` has these fields:
  - `tool`, `cmd` (the daemon command), `session`, `window` and `trace`. The trace is the same
    id the daemon log uses.
  - `args`, the redacted arguments. `args_fp` is a keyed fingerprint of the arguments.
  - `outcome`, one of `ok`, `warning`, `tool_error`, `invalid_arguments`, `transport_error`,
    `daemon_restarted` or `mcp_error`.
  - `error`, with `code`, `message`, `recovery_tool`, `recovery_then` and `next_action`.
  - `action`, with `outcome` (confirmed, unconfirmed or refused), `route` and `completion`.
  - `isolation`, `warnings`, `truncated`, `snapshot` and `wait`.
  - `result`, with `text_bytes`, `est_tokens`, `lines`, `first_line` and any image counts. At
    `full`, it also keeps `text`: what the agent read, up to 32 KB.
  - Loop context: `seq`, `prev_tool`, `gap_ms` (the agent's think time), `repeat` (the same call
    again) and `after_error`.
  - `observe`, and any one-time `notes` the agent was shown.
- `mcp.method` covers list, resource and prompt requests, and parse errors.

**Always redacted, at every level:**
- Typed text and clipboard text are replaced by their length and a fingerprint. The fingerprint
  is keyed per connection, so identical text is recognisable within one conversation but can't
  be matched across files or guessed. When an app echoes that text back (a type receipt's
  "window text now", a later screen read, an error), the echo is replaced by `‹typed <fp>›`,
  ignoring case. The only exception is text of one or two characters.
- URL queries, fragments and credentials are dropped. At `metadata`, only the scheme and host
  are kept.
- Screenshot images are counted but never stored.

At `metadata`, file paths are also reduced to their file names, and the result keeps no text
beyond its first line. `full` keeps the rendered result text, which can include what an app
displayed: window titles, document text, page labels. Secure-field values are never read by
SpaceO in the first place.

**Daemon log** (while request logging is on) has one record per request from every client:
- `client` (`cli`, `mcp` or `viewer`), `cmd`, `session`, `trace` and the timing and memory metrics;
- on failure: `error_code`, `recovery_tool` and `next_action`;
- the shape of the request, never its content: `element`, `point`, `key`, `wait_condition`,
  `since`, `text_chars` and `menu_depth`;
- for actions: `route`, `action_outcome` and `destroy_reason`.

## Run the loop

```bash
node scripts/journal-report.mjs --daemon-log ~/Library/Logs/SpaceO/daemon.log            # markdown
node scripts/journal-report.mjs --since=2026-09-23 --top=15 --json > /tmp/spaceo-loop.json
```

The report ranks **candidates**. Each one comes with the evidence that should move if the fix
works. It also shows:
- per-tool calls, errors, p50/p95 latency and token cost;
- error codes, with how often the agent actually followed the recovery hint;
- friction signals: identical retries after an error, invalid-argument names, re-reads right
  after an action (even when an observe diff was returned), truncated reads, unconfirmed
  actions, wait timeouts, isolation verdicts, and sessions left for the janitor;
- the largest and slowest calls;
- daemon failures from the CLI and the Viewer;
- how much time the MCP server adds on top of the daemon.

A good loop:

1. **Collect.** Use SpaceO normally through your agents for a day or a representative task set.
2. **Report.** Run the report and pick the top candidate you can explain.
3. **Reproduce.** Open its example traces:
   `grep -r <trace> ~/Library/Logs/SpaceO/journal ~/Library/Logs/SpaceO/daemon.log`. At `full`,
   the journal shows exactly what the agent read before and after.
4. **Fix** it with a deterministic regression test. Follow AGENTS.md: bounded inputs, no
   downgraded success claims, and no unfiltered `swift test` on a host with grants.
5. **Verify** with `make verify-release`, then use SpaceO again and rerun the report with
   `--since=<fix date>`. Check that the candidate's evidence count dropped and that no new
   signal appeared.
6. Record the change in `CHANGELOG.md`, and in `docs/AGENT_EFFICIENCY.md` for efficiency work.

The journal reflects your own apps and data. Don't paste `full` journal excerpts into tickets,
commits, or shared documents; quote codes, counts and traces instead.
