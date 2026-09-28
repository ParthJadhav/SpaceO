Privacy maintenance release for native macOS apps and Chromium browsers on Apple Silicon.

- Removes unnecessary personal signing examples and identifier output; public source history uses GitHub noreply metadata.
- Keeps raw live-test diagnostics private and checks public files for common personal-data exposure.
- Includes the installer and the existing fix that refuses to overwrite unreadable MCP client configuration.

**Viewer scope:** Run Viewer on a physical display while the controlled application runs on a SpaceO virtual display. Hosting Viewer inside a SpaceO virtual display is unsupported because intermittent stream staleness remains unresolved. The release owner explicitly accepted this limitation. Managed Electron launches remain unsupported; editors may still connect as MCP clients.

The exact signed and notarized candidate passed 1,625 deterministic Swift tests, 16 full live tests, 36 computer-use checks, focused Viewer typing/escape/hand-back checks, and staged rollback. [Qualification and owner GO](https://github.com/ParthJadhav/SpaceO/blob/QUALIFICATION_COMMIT/docs/validation/2026-09-28-privacy-release.md).

Source: `7f80fc756a664daadd7ed8d8fb422fe28e65cb01`  
Immutable tag object: `7970665e11bafa44170a0e40947392c25d0564a7`  
DMG SHA-256: `7e595ef101bcd1bc9e35efc5624322a78593cda2d6e757463178dd63b9044bee`

Use the DMG, signed checksum, and signed candidate record below. [Installation and signature verification](https://github.com/ParthJadhav/SpaceO/blob/QUALIFICATION_COMMIT/docs/INSTALL.md). Apple publisher name and Team ID remain public certificate metadata needed to authenticate signed downloads.

Repository history was rewritten for privacy. Fetch a fresh clone; do not merge old history back. Superseded release references are retired only after this replacement's public downloads are verified. GitHub-retained PR refs and cached commits require separate Support cleanup; third-party copies cannot be recalled.
