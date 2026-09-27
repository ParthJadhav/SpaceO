# SpaceO 1.0.1

This privacy maintenance release includes the one-command installer and keeps the same native-app
and Chromium scope as 1.0.0. Managed Electron application launches remain unsupported.

- Authenticate, install, and connect supported MCP clients with `install.sh`.
- Refuse to overwrite an existing client configuration that cannot be read as UTF-8.
- Remove personal signing examples and unnecessary identifier output.
- Retain live-test diagnostics privately and scan tracked public files, including symlink targets,
  for common personal data. Git history uses GitHub noreply contributor metadata.
- Bind the signed candidate provenance to the rewritten source commit and a new immutable tag.

Download the DMG, signed checksum, and signed candidate record from this release. Follow
[INSTALL.md](INSTALL.md) for publisher, checksum, and notarization verification. Publisher identity
in Developer ID certificates remains public and is required to authenticate the download.

Earlier releases are retired after this replacement is verified as part of the owner-authorized
privacy migration. Existing installed binaries continue to work; re-run the installer to update.
Old clones and GitHub's retained PR refs may still contain historical metadata until separately
cleaned up. Do not merge old history back into the rewritten branch; fetch a fresh clone instead.

See [release qualification](validation/2026-09-28-privacy-release.md) for the retained verification
record. A draft candidate is not an approved public release.
