# Agent playbook sources

The Markdown files in this directory are the single source for the agent-facing playbook that
the MCP server ships as prompts and `spaceo://docs/<name>` resources (SPAO-221, SPAO-170). They
are written for an LLM agent as the reader.

`Sources/SpaceOMCP/Playbook.swift` is generated from them and is committed so the Swift build
does not depend on Node. After editing any file here, regenerate and commit both:

```sh
node scripts/generate-playbook.mjs
```

`Tests/SpaceOKitTests/PlaybookTests.swift` fails when the generated Swift and these files drift.
This README is documentation for maintainers and is not embedded in the server.
