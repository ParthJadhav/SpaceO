PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
SWIFT ?= swift
NODE ?= node

.PHONY: build release test test-live verify-release install uninstall viewer \
	release-check release-dry-run release-preflight release-package verify-distribution

build:
	$(SWIFT) build

release:
	$(SWIFT) build -c release

test:
	$(SWIFT) test --filter UnitTests

test-live:
	@test "$$SPACEO_RUN_INTEGRATION_TESTS" = "1" || { \
		echo "refusing: live tests mutate WindowServer; use a disposable graphical login and run:" >&2; \
		echo "  SPACEO_RUN_INTEGRATION_TESTS=1 make test-live" >&2; \
		exit 2; \
	}
	@echo "warning: running live display/input tests in the current graphical login"
	$(SWIFT) test --filter IntegrationTests

verify-release: release test
	$(NODE) scripts/mcp-smoke.mjs .build/release/spaceo

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
