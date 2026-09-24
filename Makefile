PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
SWIFT ?= swift
NODE ?= node

.PHONY: build release signed test test-live test-live-full verify-release computer-use-check \
		computer-use-check-full install uninstall viewer install-viewer \
		release-check release-dry-run release-preflight release-package verify-distribution \
		verify-release-candidate

build:
	$(SWIFT) build

release:
	$(SWIFT) build -c release

# Stable local artifacts for permission-bearing development and live audits.
signed: release
	bash scripts/make-signed-build.sh

test:
	SWIFT="$(SWIFT)" NODE="$(NODE)" bash scripts/test.sh safe

test-live:
	SWIFT="$(SWIFT)" bash scripts/test.sh live

# Qualification gate: a live test that skips, or a filter that selects fewer tests than the suite
# defines, fails the run. Only meaningful on a host with the Accessibility and Screen Recording
# grants; see docs/LIVE_TESTS.md.
test-live-full:
	SWIFT="$(SWIFT)" bash scripts/test.sh live --require-full

verify-release: release test
	$(NODE) scripts/mcp-smoke.mjs .build/release/spaceo

computer-use-check: release
	$(NODE) scripts/computer-use-check.mjs .build/release/spaceo --suite=all

# Release-time gate: a suite skipped for a missing host application fails the run.
computer-use-check-full: release
	$(NODE) scripts/computer-use-check.mjs .build/release/spaceo --suite=all --require-full

viewer: release
	bash scripts/make-viewer-app.sh ".build/release/SpaceOViewer" ".build/SpaceO Viewer.app"

install-viewer:
	bash scripts/install-viewer-app.sh

# Replacing the file does not replace a daemon already running the previous build, so say which
# version is still serving. Read-only: it pings, never restarts. Skipped for staged (DESTDIR)
# installs, whose binary is not the one this user runs.
install: release
	install -d "$(DESTDIR)$(BINDIR)"
	@previous="$$(test -x "$(DESTDIR)$(BINDIR)/spaceo" && "$(DESTDIR)$(BINDIR)/spaceo" version 2>/dev/null | awk '{print $$2}')"; \
	install -m 755 .build/release/spaceo "$(DESTDIR)$(BINDIR)/spaceo"; \
	installed="$$("$(DESTDIR)$(BINDIR)/spaceo" version 2>/dev/null | awk '{print $$2}')"; \
	echo "installed $(DESTDIR)$(BINDIR)/spaceo $$installed$${previous:+ (was $$previous)}"; \
	if [ -z "$(DESTDIR)" ]; then \
		daemon_json="$$("$(BINDIR)/spaceo" daemon wait --timeout 1 --json 2>/dev/null)"; \
		running="$$(printf '%s' "$$daemon_json" | sed -n 's/.*"daemon":{[^}]*"version":"\([^"]*\)".*/\1/p')"; \
		running_sha="$$(printf '%s' "$$daemon_json" | sed -n 's/.*"executableSHA256":"\([0-9a-f]*\)".*/\1/p')"; \
		installed_sha="$$(shasum -a 256 "$(BINDIR)/spaceo" | awk '{print $$1}')"; \
		if [ -n "$$running" ] && [ "$$running" != "$$installed" ]; then \
			echo "installed $$installed over $$running; the running daemon is still $$running → spaceo daemon restart --operator"; \
		elif [ -n "$$running_sha" ] && [ "$$running_sha" != "$$installed_sha" ]; then \
			echo "the running daemon is an older build of $$running → spaceo daemon restart --operator"; \
		elif [ -n "$$running" ]; then \
			echo "the running daemon is already this build ($$running)"; \
		fi; \
	fi

uninstall:
	rm -f "$(DESTDIR)$(BINDIR)/spaceo"
	@echo "removed $(DESTDIR)$(BINDIR)/spaceo"

release-check:
	bash scripts/release.sh check

release-dry-run:
	bash scripts/release.sh dry-run

release-preflight:
	bash scripts/release.sh preflight

release-package:
	bash scripts/release.sh package

verify-distribution:
	@test -n "$(ARTIFACT)" || { \
		echo "usage: make verify-distribution ARTIFACT=.release/VERSION/SpaceO-VERSION-macOS-ARCH.dmg" >&2; \
		exit 2; \
	}
	bash scripts/release.sh verify "$(ARTIFACT)"

verify-release-candidate:
	@test -n "$(CANDIDATE)" || { \
		echo "usage: make verify-release-candidate CANDIDATE=.release/VERSION/SpaceO-VERSION-macOS-arm64.candidate.txt" >&2; \
		exit 2; \
	}
	bash scripts/release.sh verify-candidate "$(CANDIDATE)"
