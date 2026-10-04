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
