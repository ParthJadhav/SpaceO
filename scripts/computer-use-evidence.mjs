// Evidence rules shared by the live matrix and its app-free regression tests.
export function toolResult(response) {
  const result = response?.result;
  if (response?.error || !result || !Array.isArray(result.content)) {
    return {
      ok: false,
      text: response?.error?.message ?? "MCP returned no valid tool result",
      image: null,
      unconfirmed: false,
    };
  }
  const text = result.content.filter((c) => c?.type === "text" && typeof c.text === "string")
    .map((c) => c.text).join("\n");
  const image = result.content.find((c) => c?.type === "image" && typeof c.data === "string")?.data || null;
  return { ok: result.isError !== true, text, image, unconfirmed: /UNCONFIRMED:/.test(text) };
}

export function imagesChanged(before, after) {
  return before.ok && after.ok && Boolean(before.image) && Boolean(after.image)
    && before.image !== after.image;
}

export function fixturePageState(response) {
  if (!response?.ok) return { ok: false, reason: "tool_failed" };
  const match = response.text?.match(/CU ev=([\w+]+) y=(\d+)/);
  if (!match) return { ok: false, reason: "fixture_state_missing" };
  return { ok: true, events: match[1] === "none" ? [] : match[1].split("+"),
    scrollY: Number(match[2]), raw: match[0] };
}

export function pageElementFor(response, label) {
  if (!response?.ok || typeof response.text !== "string") return null;
  for (const line of response.text.split("\n")) {
    const match = line.match(/^\s*\[(w\d+)\].*? — (.*?)  at \((\d+),(\d+)\)(?:\s|$)/);
    if (match?.[2] === label && !line.includes("(disabled)")) {
      return { element: match[1], x: Number(match[3]), y: Number(match[4]) };
    }
  }
  return null;
}

export function isolationStatus(response) {
  if (!response.ok) return "fail";
  const verdict = response.text.match(/^\s*isolation:\s*(intact|partial|breached)(?=\s|$)/m)?.[1];
  if (verdict === "partial") return "blocked";
  return verdict === "intact" ? "pass" : "fail";
}

// Keep only fixed report codes. Evidence, process IDs, coordinates and arbitrary tool text
// remain private; this follow-up observation does not reconstruct the earlier refusal.
export function isolationDiagnostics(response) {
  const dimensions = new Set(["menu_bar_owner", "window_server_front_process", "key_input_route",
    "text_input_route", "cursor_location", "active_space"]);
  const checks = {};
  const text = typeof response?.text === "string" ? response.text : "";
  for (const match of text.matchAll(/^- ([a-z_]+): (passed|failed|unknown) \[(observed|inferred|unknown)\]/gm)) {
    if (!dimensions.has(match[1])) continue;
    if (checks[match[1]]) return { observed: false };
    checks[match[1]] = { status: match[2], coverage: match[3] };
  }
  return Object.keys(checks).length ? { observed: true, checks } : { observed: false };
}

// MCP reuses an already running daemon instead of replacing it, and the daemon performs every
// display operation, so this harness's environment does not establish the run's configuration.
// Record only the override the daemon reports (`spaceo pool --json`), and refuse a run whose
// daemon is silent, inconsistent, or differs from the requested mode.
export function daemonTestingOverride(pool, requested) {
  const isObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
  // Daemons report true, or omit the field for normal admission; anything else is unknown.
  const flag = (value) => (value === true ? true
    : value === undefined || value === null || value === false ? false : null);
  const daemon = pool?.daemon;
  let reported = null;
  if (pool?.ok === true && isObject(daemon?.hostHealth) && isObject(pool.limits)) {
    const fields = [daemon.hostHealth.testingOverride, pool.limits.creationRateTestingOverride];
    if (isObject(daemon.displaySafety)) fields.push(daemon.displaySafety.creationRateTestingOverride);
    const values = new Set(fields.map(flag));
    if (values.size === 1 && !values.has(null)) [reported] = values;
  }
  const mode = (value) => (value ? "the diagnostic testing override" : "normal admission");
  if (reported === null) {
    return { reported, ok: false,
      detail: "the daemon did not report one consistent testing-override state; inspect `spaceo pool --json`" };
  }
  if (reported !== requested) {
    return { reported, ok: false,
      detail: `this run requests ${mode(requested)} but the running daemon uses ${mode(reported)}; `
        + "use a daemon started with the same SPACEO_LIVE_TESTS and SPACEO_TESTING_HOST values" };
  }
  return { reported, ok: true, detail: `the daemon reports ${mode(reported)}` };
}
