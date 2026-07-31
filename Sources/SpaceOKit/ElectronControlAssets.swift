import Foundation

/// Embedded VS Code extension used as a semantic renderer adapter.
///
/// It is written into a per-launch 0700 directory and loaded through `--extensions-dir`, so the
/// agent instance neither installs anything into the user's extension set nor runs the user's
/// extensions. Keeping these tiny assets embedded also preserves `make install`'s single-binary
/// distribution contract.
enum ElectronControlAssets {
    static let socketEnvironmentKey = "SPACEO_ELECTRON_CONTROL_SOCKET"
    static let tokenEnvironmentKey = "SPACEO_ELECTRON_CONTROL_TOKEN"
    static let extensionDirectoryName = "spaceo.spaceo-electron-control-0.0.1"

    static let packageJSON = #"""
    {
      "name": "spaceo-electron-control",
      "displayName": "SpaceO Electron Control",
      "version": "0.0.1",
      "publisher": "spaceo",
      "engines": {
        "vscode": "^1.90.0"
      },
      "main": "./extension.js",
      "activationEvents": [
        "*"
      ],
      "capabilities": {
        "untrustedWorkspaces": {
          "supported": true
        }
      }
    }
    """#

    static let extensionJavaScript = #"""
    const crypto = require("node:crypto");
    const fs = require("node:fs");
    const net = require("node:net");
    const vscode = require("vscode");

    const MAX_REQUEST_BYTES = 16 * 1024;
    const socketPath = process.env.SPACEO_ELECTRON_CONTROL_SOCKET;
    const expectedToken = process.env.SPACEO_ELECTRON_CONTROL_TOKEN;

    function sameToken(candidate) {
      if (typeof candidate !== "string" || typeof expectedToken !== "string") return false;
      const actual = Buffer.from(candidate);
      const expected = Buffer.from(expectedToken);
      return actual.length === expected.length && crypto.timingSafeEqual(actual, expected);
    }

    function ranges(editor) {
      return editor.visibleRanges.map((range) => [
        range.start.line,
        range.start.character,
        range.end.line,
        range.end.character
      ]);
    }

    function equalRanges(left, right) {
      return JSON.stringify(left) === JSON.stringify(right);
    }

    function delay(milliseconds) {
      return new Promise((resolve) => setTimeout(resolve, milliseconds));
    }

    function editorState() {
      const editor = vscode.window.activeTextEditor;
      if (!editor) throw new Error("no active text editor");
      const visibleEditors = vscode.window.visibleTextEditors;
      if (visibleEditors.length !== 1 || visibleEditors[0] !== editor) {
        throw new Error("semantic scrolling requires exactly one visible active editor");
      }
      return {
        editor,
        document: editor.document.uri.toString(),
        visible: ranges(editor)
      };
    }

    async function handle(request) {
      if (!sameToken(request.token)) throw new Error("authentication failed");
      if (request.version !== 1) throw new Error("unsupported protocol version");
      if (request.command === "ping") {
        const state = editorState();
        return {
          ok: true,
          document: state.document,
          visible: state.visible
        };
      }
      if (request.command !== "scroll") throw new Error("unsupported control request");
      if (request.direction !== "up" && request.direction !== "down") {
        throw new Error("invalid scroll direction");
      }
      if (!Number.isInteger(request.pages) || request.pages < 1 || request.pages > 100) {
        throw new Error("scroll pages must be from 1 through 100");
      }
      const { editor, document } = editorState();
      const before = ranges(editor);
      await vscode.commands.executeCommand("editorScroll", {
        to: request.direction,
        by: "page",
        value: request.pages,
        revealCursor: false
      });
      let after = ranges(editor);
      for (let attempt = 0; attempt < 40 && equalRanges(before, after); attempt += 1) {
        await delay(25);
        after = ranges(editor);
      }
      if (equalRanges(before, after)) {
        throw new Error("editor accepted the command but its visible range did not change");
      }
      return {
        ok: true,
        changed: true,
        before,
        after,
        document
      };
    }

    function activate(context) {
      if (!socketPath || !expectedToken) return;
      try {
        fs.unlinkSync(socketPath);
      } catch (error) {
        if (error && error.code !== "ENOENT") throw error;
      }
      const server = net.createServer((connection) => {
        let input = "";
        let handled = false;
        connection.setEncoding("utf8");
        connection.on("data", async (chunk) => {
          if (handled) return;
          input += chunk;
          if (Buffer.byteLength(input, "utf8") > MAX_REQUEST_BYTES) {
            handled = true;
            connection.end(JSON.stringify({ ok: false, error: "request too large" }) + "\n");
            return;
          }
          const newline = input.indexOf("\n");
          if (newline < 0) return;
          handled = true;
          try {
            const response = await handle(JSON.parse(input.slice(0, newline)));
            connection.end(JSON.stringify(response) + "\n");
          } catch (error) {
            connection.end(JSON.stringify({ ok: false, error: String(error) }) + "\n");
          }
        });
      });
      // A late bind failure must make the private controller unavailable, not crash Cursor's
      // extension host. SpaceO will fail closed when the socket is absent.
      server.on("error", () => {});
      server.listen(socketPath, () => {
        fs.chmodSync(socketPath, 0o600);
      });
      context.subscriptions.push({
        dispose: () => {
          server.close();
          try {
            fs.unlinkSync(socketPath);
          } catch {}
        }
      });
    }

    function deactivate() {}

    module.exports = { activate, deactivate };
    """#
}
