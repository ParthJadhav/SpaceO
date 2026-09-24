# Validated probes for the SpaceO investigation. See ../FINDINGS.md.
#
#   make            build everything
#   make spaces     read-only: dump the WindowServer space graph
#   make caps       read-only: TCC + private-symbol capability gate
#   make vdisplay-classes  read-only: introspect CGVirtualDisplay* on this build
#   make demo       research workflow
#
# Nothing here needs SIP disabled. probe4/demo needs Accessibility + Screen Recording
# for the calling terminal.

CC      := clang
FRAMEWORKS := -framework Foundation -framework AppKit -framework ApplicationServices -framework CoreGraphics
CFLAGS  := -fobjc-arc -Wno-deprecated-declarations -Wno-objc-method-access

BINS := probe1 probe2 probe3 probe4 probe5 probe6 probe7 vdisplay

all: $(BINS)

probe1: probe1.m           # space graph (read-only)
	$(CC) -o $@ $< -framework Foundation -framework CoreGraphics -Wno-format-invalid-specifier \
	  -F/System/Library/PrivateFrameworks -framework SkyLight

probe2: probe2.m           # capability gate (read-only, no TCC prompts)
	$(CC) -o $@ $< $(FRAMEWORKS) -Wno-deprecated-declarations

probe3: probe3.m           # CGVirtualDisplay class introspection (read-only)
	$(CC) -o $@ $< -framework Foundation -framework CoreGraphics

probe4: probe4.m           # end-to-end: relocate + focus-without-raise + per-PID keys
	$(CC) -o $@ $< $(FRAMEWORKS) $(CFLAGS)

probe5: probe5.m           # display arrangement / diagonal parking
	$(CC) -o $@ $< -framework Foundation -framework CoreGraphics

probe6: probe6.m           # N simultaneous virtual displays
	$(CC) -o $@ $< -framework Foundation -framework CoreGraphics $(CFLAGS)

probe7: probe7.m           # proves CGConfigureDisplayOrigin pins + poisons virtual displays
	$(CC) -o $@ $< -framework Foundation -framework CoreGraphics $(CFLAGS)

vdisplay: vdisplay.m       # long-lived headless agent display
	$(CC) -o $@ $< -framework Foundation -framework CoreGraphics $(CFLAGS)

spaces: probe1
	./probe1

caps: probe2
	./probe2

vdisplay-classes: probe3
	./probe3

# Full demo. Starts an agent display, parks it diagonally, opens TextEdit on it,
# types into it from the background, screenshots it, then tears everything down.
demo: vdisplay probe4 probe5
	@echo "scratch" > /tmp/spaceo-scratch.txt
	@./vdisplay 1920 1080 1 & echo $$! > /tmp/spaceo-vd.pid; sleep 2
	@DID=$$(./probe5 0 0 0 2>/dev/null | awk '/main=0/{print $$2}' | head -1 | cut -d= -f2); \
	 echo "agent display = $$DID"; \
	 ./probe5 $$DID 12000 9000 >/dev/null; \
	 open -g -a TextEdit /tmp/spaceo-scratch.txt; sleep 3; \
	 ./probe4 $$(pgrep -x TextEdit) $$DID
	@osascript -e 'tell application "TextEdit" to close every document without saving' \
	           -e 'tell application "TextEdit" to quit' 2>/dev/null || true
	@kill $$(cat /tmp/spaceo-vd.pid) 2>/dev/null || true
	@rm -f /tmp/spaceo-vd.pid /tmp/spaceo-scratch.txt
	@echo "torn down."

# Reproduces the finding that killed geometric parking (see ../FINDINGS.md 4.1).
parking-evidence: probe7
	@for m in 0 1; do ./probe7 $$m; echo "---"; done

clean:
	rm -f $(BINS)

.PHONY: all spaces caps vdisplay-classes demo parking-evidence clean
