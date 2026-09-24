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

export function isolationStatus(response) {
  if (!response.ok) return "fail";
  const verdict = response.text.match(/^\s*isolation:\s*(intact|partial|breached)(?=\s|$)/m)?.[1];
  if (verdict === "partial") return "blocked";
  return verdict === "intact" ? "pass" : "fail";
}
