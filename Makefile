PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
SWIFT ?= swift
NODE ?= node

.PHONY: build release test test-live verify-release install viewer

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
