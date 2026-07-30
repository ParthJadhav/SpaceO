# Installing a SpaceO release

SpaceO's supported public distribution model is a versioned Developer ID macOS disk image
containing two signed executables:

- `spaceo`, the CLI, daemon, and MCP server
- `SpaceO Viewer.app`, the optional graphical console

This is a direct Developer ID distribution, not a Mac App Store release. The disk image and Viewer
must be notarized and stapled. Each release also includes a SHA-256
sidecar and a detached Developer ID signature over that sidecar. Official SpaceO releases are
signed by Team ID `75LRT8TRQY`. Do not install an artifact whose publisher, checksum, staple,
signature, or Gatekeeper assessment fails.

SpaceO uses private macOS behavior and its deployment target is not a compatibility guarantee.
Review “Requirements and support status” in the project README and run `spaceo doctor` on every
intended host before creating a session.

No signed, notarized, independently qualified public release is currently recorded in this
repository. The commands below define how to verify a candidate or future release; they do not
assert that version `1.0.0` or any downloadable artifact has passed the
[public-release gates](RELEASE_POLICY.md).

## Verify and install

Download the `.dmg`, `.sha256`, and `.sha256.sig` files from the same release. Authenticate the
checksum as an official SpaceO publisher artifact before using it:

```bash
codesign --verify \
  --detached SpaceO-1.0.0-macOS-arm64.sha256.sig \
  --strict --verbose=2 \
  -R '=anchor apple generic and certificate leaf[subject.OU] = "75LRT8TRQY" and identifier "dev.spaceo.release-checksum"' \
  SpaceO-1.0.0-macOS-arm64.sha256
```

Only after that command succeeds, verify the disk image from the directory containing all three
files:

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
codesign --verify --strict --verbose=2 \
  -R '=anchor apple generic and certificate leaf[subject.OU] = "75LRT8TRQY" and identifier "dev.spaceo.cli"' \
  "$SPACEO_MOUNT/spaceo"
codesign --verify --deep --strict --verbose=2 \
  -R '=anchor apple generic and certificate leaf[subject.OU] = "75LRT8TRQY" and identifier "dev.spaceo.viewer"' \
  "$SPACEO_MOUNT/SpaceO Viewer.app"
codesign --display --verbose=4 "$SPACEO_MOUNT/spaceo"
codesign --display --verbose=4 "$SPACEO_MOUNT/SpaceO Viewer.app"
spctl --assess --type execute --verbose=4 "$SPACEO_MOUNT/spaceo"
spctl --assess --type execute --verbose=4 "$SPACEO_MOUNT/SpaceO Viewer.app"
```

Both `codesign --display` results must name a `Developer ID Application` authority, the exact
`TeamIdentifier=75LRT8TRQY`, and a `Timestamp`. Merely seeing some Developer ID authority is not
publisher authentication. The release pipeline applies these designated requirements before it
executes the mounted CLI.

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

Keep the previous release disk image, checksum, and detached checksum signature until the new
version has passed `spaceo doctor` and your normal workflow.

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

SpaceO has no general-purpose database or user-content migration, but it does keep a versioned,
per-socket session-recovery ledger under the user's Application Support directory. A clean
`daemon stop` tears down attached sessions and prunes their completed records. Interrupted or
blocked cleanup remains durable for the next daemon to fence and resolve; do not delete that
ledger to force a rollback. Review [Session ownership and recovery](SESSION_RECOVERY.md) before
switching versions while detached recovery records remain.

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

The commands in this section implement packaging and trust verification. They do not replace the
independent live qualification and explicit approval required by the
[release policy](RELEASE_POLICY.md).

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
SPACEO_CODESIGN_IDENTITY='Developer ID Application: Parth Jadhav (75LRT8TRQY)' \
SPACEO_NOTARY_PROFILE='your-existing-profile' \
make release-preflight
```

or an App Store Connect API key:

```bash
SPACEO_CODESIGN_IDENTITY='Developer ID Application: Parth Jadhav (75LRT8TRQY)' \
SPACEO_NOTARY_KEY='/secure/path/AuthKey_KEYID.p8' \
SPACEO_NOTARY_KEY_ID='KEYID' \
SPACEO_NOTARY_ISSUER='ISSUER-UUID' \
make release-preflight
```

The release script does not discover, create, or overwrite a notarytool keychain profile. It also
does not fall back to ad-hoc, Apple Development, or a different Developer ID team. Missing,
partial, mixed, invalid, unreadable, or non-SpaceO credential inputs stop preflight before the
build.

First run the live qualification procedure from the README on a qualified Apple Silicon host in
a disposable login. It writes `.build/spaceo-live-qualification.txt`; missing TCC grants,
applications, runtime APIs, or any skipped test fail the qualification. Copy that record alongside
the exact Git checkout being packaged, then run `make release-package` with the signing
environment above and:

```bash
SPACEO_LIVE_QUALIFICATION_RECORD=/path/to/spaceo-live-qualification.txt \
make release-package
```

The pipeline:

1. checks repository and embedded versions;
2. verifies that the live record passed every discovered integration test for the exact commit
   and arm64 architecture;
3. runs the safe test suite, optimized build, and MCP black-box smoke test;
4. signs the CLI and Viewer with hardened runtime and a secure timestamp;
5. verifies both with `codesign --verify --strict`;
6. notarizes and staples the Viewer;
7. builds, notarizes, and staples the versioned disk image;
8. signs the checksum sidecar with the SpaceO publisher identity;
9. authenticates that sidecar, then verifies the checksum, stapled ticket, exact publisher
   signatures, embedded versions, and Gatekeeper assessments from a freshly mounted image.

Artifacts are written under `.release/VERSION/` as a DMG, checksum, and detached checksum
signature. `make verify-distribution ARTIFACT=...` requires all three and repeats the final
integrity and trust checks without publishing.

The `Signed release candidate and publication` GitHub Actions workflow first calls the separate
`Live qualification` workflow on a self-hosted runner labelled `spaceo-live-qualified`. The
`live-qualification` environment must supply `SPACEO_QUALIFIED_HOST=1` and
`SPACEO_DISPOSABLE_LOGIN=1`; repository configuration must independently enforce any desired
reviewers or protection. Candidate packaging cannot start until the live record for its exact tag
commit is downloaded and verified.

The `candidate` job then uses the same release script. Hosted build and release jobs select Xcode
26.0.1 / Swift 6.2 explicitly and fail before tests if the runner no longer provides that exact
compatible toolchain. Candidate creation requires these repository or `release`
protected-environment secrets:

- `DEVELOPER_ID_APPLICATION_P12_BASE64`
- `DEVELOPER_ID_APPLICATION_P12_PASSWORD`
- `DEVELOPER_ID_APPLICATION_IDENTITY`
- `NOTARY_API_KEY_P8_BASE64`
- `NOTARY_API_KEY_ID`
- `NOTARY_API_ISSUER_ID`

The workflow imports credentials into an ephemeral keychain and removes the temporary key and
certificate files on exit. After full verification it uploads an immutable candidate artifact
containing the DMG, checksum and detached signature, retained live record, and a signed
`.candidate.txt` record. That record binds every retained file digest to the version, arm64
architecture, commit, tag object, repository, workflow run, and attempt. A manual dispatch
validates its source under `refs/tags/`, rejects branches and commits not contained in the default
branch, packages the explicit tag, and stops after retaining this candidate.

A tag push also creates a waiting `publication` job. Before approving its protected
`release-publication` environment, an independent reviewer must download that exact candidate,
run:

```bash
make verify-release-candidate \
  CANDIDATE=/path/to/SpaceO-VERSION-macOS-arm64.candidate.txt
```

and complete and retain the intended-distribution qualification required by the release policy.
The automated commit-bound live record in the bundle remains required, but does not substitute for
that post-artifact human qualification. After approval, the publication job downloads the
candidate by immutable artifact ID, re-authenticates the signed candidate metadata, repeats the
fresh-mount distribution checks, and verifies the remote tag object before publishing those exact
files. It has no signing or notarization secrets and performs no build. Configure required
reviewers on `release-publication`; the repository cannot configure or attest that protection.
