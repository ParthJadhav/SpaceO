# Installing a SpaceO release

SpaceO releases are distributed as a versioned macOS disk image containing two Developer-ID
signed executables:

- `spaceo`, the CLI, daemon, and MCP server
- `SpaceO Viewer.app`, the optional graphical console

The disk image and Viewer are notarized and stapled. Each release also includes a SHA-256
sidecar named like the disk image. Do not install an artifact whose checksum, staple, signature,
or Gatekeeper assessment fails.

SpaceO uses private macOS behavior and its deployment target is not a compatibility guarantee.
Review “Requirements and support status” in the project README and run `spaceo doctor` on every
intended host before creating a session.

## Verify and install

Download both files from the same release, then verify the checksum from the directory containing
them:

```bash
shasum -a 256 -c SpaceO-1.0.0-macOS-arm64.sha256
```

Ask Gatekeeper to assess the stapled disk image before mounting it:

```bash
spctl --assess --type open --context context:primary-signature --verbose=4 \
  SpaceO-1.0.0-macOS-arm64.dmg
```

Mount it at a private temporary path and verify both payload signatures:

```bash
SPACEO_MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/spaceo-install.XXXXXX")"
hdiutil attach SpaceO-1.0.0-macOS-arm64.dmg \
  -readonly -nobrowse -mountpoint "$SPACEO_MOUNT"
codesign --verify --strict --verbose=2 "$SPACEO_MOUNT/spaceo"
codesign --verify --deep --strict --verbose=2 "$SPACEO_MOUNT/SpaceO Viewer.app"
codesign --display --verbose=4 "$SPACEO_MOUNT/spaceo"
codesign --display --verbose=4 "$SPACEO_MOUNT/SpaceO Viewer.app"
spctl --assess --type execute --verbose=4 "$SPACEO_MOUNT/spaceo"
spctl --assess --type execute --verbose=4 "$SPACEO_MOUNT/SpaceO Viewer.app"
```

Both `codesign --display` results must name a `Developer ID Application` authority, a Team
Identifier, and a `Timestamp`. The release pipeline checks these fields automatically.

Install without administrator privileges:

```bash
install -d "$HOME/.local/bin" "$HOME/Applications"
install -m 755 "$SPACEO_MOUNT/spaceo" "$HOME/.local/bin/spaceo"
ditto "$SPACEO_MOUNT/SpaceO Viewer.app" "$HOME/Applications/SpaceO Viewer.app"
hdiutil detach "$SPACEO_MOUNT"
rmdir "$SPACEO_MOUNT"
"$HOME/.local/bin/spaceo" version
```

Make sure `$HOME/.local/bin` is on `PATH`, or use its absolute path in MCP configuration. The
Viewer can instead be dragged to the disk image's `Applications` shortcut to install it for all
users; macOS will request administrator approval when needed.

Grant Accessibility to the process that runs `spaceo` and grant Accessibility plus Screen
Recording to `SpaceO Viewer.app`. SpaceO never requires SIP to be disabled.

## Upgrade

Keep the previous release disk image and checksum until the new version has passed `spaceo
doctor` and your normal workflow.

1. Stop the running daemon with the currently installed binary:

   ```bash
   "$HOME/.local/bin/spaceo" daemon stop
   ```

2. Verify and mount the new release using the procedure above.
3. Replace the CLI with `install -m 755` and the Viewer with `ditto`.
4. Confirm `spaceo version`, run `spaceo doctor`, and restart MCP clients.

The CLI path and Viewer bundle identifier are stable across releases, so MCP configuration and
Viewer privacy grants should remain associated with the installation. Never replace a running
daemon's binary without stopping it first.

## Roll back

Stop the daemon, verify and mount the previously retained release, then install its CLI and
Viewer over the current version using the same commands. Confirm the older version before
restarting clients:

```bash
"$HOME/.local/bin/spaceo" version
"$HOME/.local/bin/spaceo" doctor
```

SpaceO currently has no persistent database or migration step. Its daemon sessions are
process-local, so stopping the daemon tears them down before rollback.

## Uninstall

Stop SpaceO before removing either executable:

```bash
"$HOME/.local/bin/spaceo" daemon stop
rm -f "$HOME/.local/bin/spaceo"
rm -rf "$HOME/Applications/SpaceO Viewer.app"
```

If the Viewer was installed system-wide, remove `/Applications/SpaceO Viewer.app` instead (macOS
may request administrator approval). Remove SpaceO entries from MCP client configuration
separately.

Viewer-specific privacy decisions can optionally be removed after uninstall:

```bash
tccutil reset Accessibility dev.spaceo.viewer
tccutil reset ScreenCapture dev.spaceo.viewer
```

Do not reset Accessibility or Screen Recording globally: the CLI inherits the identity of the
terminal, IDE, or MCP host that launches it, and a global reset would affect unrelated apps.

## Maintainer release procedure

`VERSION` is the canonical release number; `SpaceOVersion.current` embeds the same value into the
CLI and MCP server. `scripts/release.sh check` refuses a mismatch. Use only numeric
`MAJOR.MINOR.PATCH` releases so the value is also valid for both Viewer bundle version fields.

Inspect the plan without signing, uploading, or publishing anything:

```bash
make release-dry-run
```

A public package requires an explicitly selected `Developer ID Application` identity and
deliberate notarization credentials. Choose either an existing notarytool keychain profile:

```bash
SPACEO_CODESIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
SPACEO_NOTARY_PROFILE='your-existing-profile' \
make release-preflight
```

or an App Store Connect API key:

```bash
SPACEO_CODESIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
SPACEO_NOTARY_KEY='/secure/path/AuthKey_KEYID.p8' \
SPACEO_NOTARY_KEY_ID='KEYID' \
SPACEO_NOTARY_ISSUER='ISSUER-UUID' \
make release-preflight
```

The release script does not discover, create, or overwrite a notarytool keychain profile. It also
does not fall back to ad-hoc or Apple Development signing. Missing, partial, mixed, invalid, or
unreadable credential inputs stop preflight before the build.

Run `make release-package` with the same environment. The pipeline:

1. checks repository and embedded versions;
2. runs the test suite, optimized build, and MCP black-box smoke test;
3. signs the CLI and Viewer with hardened runtime and a secure timestamp;
4. verifies both with `codesign --verify --strict`;
5. notarizes and staples the Viewer;
6. builds, notarizes, and staples the versioned disk image;
7. verifies the checksum, stapled ticket, signatures, embedded versions, and Gatekeeper
   assessments from a freshly mounted image.

Artifacts are written under `.release/VERSION/`. `make verify-distribution ARTIFACT=...` repeats
the final integrity and trust checks without publishing.

The `Signed release` GitHub Actions workflow uses the same script. It requires these repository
or protected-environment secrets:

- `DEVELOPER_ID_APPLICATION_P12_BASE64`
- `DEVELOPER_ID_APPLICATION_P12_PASSWORD`
- `DEVELOPER_ID_APPLICATION_IDENTITY`
- `NOTARY_API_KEY_P8_BASE64`
- `NOTARY_API_KEY_ID`
- `NOTARY_API_ISSUER_ID`

The workflow imports credentials into an ephemeral keychain, removes the temporary key and
certificate files on exit, and reaches the GitHub release publication step only after the full
package verification succeeds. Tag pushes publish; a manual dispatch checks out and packages the
explicit tag but only retains the verified workflow artifact.
