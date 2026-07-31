PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
SWIFT ?= swift
NODE ?= node

.PHONY: build release test test-live verify-release computer-use-check install uninstall viewer \
		release-check release-dry-run release-preflight release-package verify-distribution \
		verify-release-candidate

build:
	$(SWIFT) build

release:
	$(SWIFT) build -c release

test:
	SWIFT="$(SWIFT)" bash scripts/test.sh safe

test-live:
	SWIFT="$(SWIFT)" bash scripts/test.sh live

verify-release: release test
	$(NODE) scripts/mcp-smoke.mjs .build/release/spaceo

computer-use-check: release
	$(NODE) scripts/computer-use-check.mjs .build/release/spaceo --suite=all

viewer: release
	bash scripts/make-viewer-app.sh ".build/release/SpaceOViewer" ".build/SpaceO Viewer.app"

install: release
	install -d "$(DESTDIR)$(BINDIR)"
	install -m 755 .build/release/spaceo "$(DESTDIR)$(BINDIR)/spaceo"
	@echo "installed $(DESTDIR)$(BINDIR)/spaceo"

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
