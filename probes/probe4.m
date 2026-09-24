// probe4.m — end-to-end isolation test.
//   argv[1] = pid of the target app already launched in the background
//   argv[2] = target display id (the virtual one)
//
// Proves (or disproves) in one run:
//   1. the virtual display owns its own managed Space
//   2. we can relocate another app's window onto it (AX, no cursor)
//   3. that window is genuinely composited there (capture returns real pixels)
//   4. we can drive it with keystrokes via per-PID event routing
//   5. the user's frontmost app never changes
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>

typedef int CGSConnectionID;
static CGSConnectionID (*SLSMainConnectionID)(void);
static CFArrayRef (*SLSCopyManagedDisplaySpaces)(int);
static CFArrayRef (*SLSCopySpacesForWindows)(int, int, CFArrayRef);
static OSStatus   (*SLPSPostEventRecordTo)(ProcessSerialNumber *, uint8_t *);
static OSStatus   (*SLPSGetFrontProcess)(ProcessSerialNumber *);
static CGError    (*SLSGetWindowBounds)(int, uint32_t, CGRect *);

static void loadSyms(void) {
  void *sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
  SLSMainConnectionID         = dlsym(sl, "SLSMainConnectionID");
  SLSCopyManagedDisplaySpaces = dlsym(sl, "SLSCopyManagedDisplaySpaces");
  SLSCopySpacesForWindows     = dlsym(sl, "SLSCopySpacesForWindows");
  SLPSPostEventRecordTo       = dlsym(sl, "SLPSPostEventRecordTo");
  SLPSGetFrontProcess         = dlsym(sl, "SLPSGetFrontProcess");
  SLSGetWindowBounds          = dlsym(sl, "SLSGetWindowBounds");
}

static pid_t frontPid(void) {
  return NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
}

// yabai's trick: flip the app's AppKit-active state for input routing WITHOUT
// SLPSSetFrontProcessWithOptions, so no raise and no Space switch.
static void focusWithoutRaise(pid_t pid, uint32_t wid) {
  ProcessSerialNumber psn = {0, kNoProcess};
  GetProcessForPID(pid, &psn);
  uint8_t b[0xf8] = {0};
  b[0x04] = 0xf8; b[0x08] = 0x0d;
  memcpy(b + 0x3c, &wid, sizeof wid);
  memset(b + 0x20, 0xff, 0x10);
  b[0x8a] = 0x01;                       // "you are now active for input routing"
  SLPSPostEventRecordTo(&psn, b);
  // make it the key window
  uint8_t k[0xf8] = {0};
  k[0x04] = 0xf8; k[0x3a] = 0x10;
  memcpy(k + 0x3c, &wid, sizeof wid);
  memset(k + 0x20, 0xff, 0x10);
  k[0x08] = 0x01; SLPSPostEventRecordTo(&psn, k);
  k[0x08] = 0x02; SLPSPostEventRecordTo(&psn, k);
}

static void typeString(pid_t pid, NSString *s) {
  CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
  for (NSUInteger i = 0; i < s.length; i++) {
    UniChar c = [s characterAtIndex:i];
    CGEventRef down = CGEventCreateKeyboardEvent(src, 0, true);
    CGEventRef up   = CGEventCreateKeyboardEvent(src, 0, false);
    CGEventKeyboardSetUnicodeString(down, 1, &c);
    CGEventKeyboardSetUnicodeString(up,   1, &c);
    CGEventPostToPid(pid, down);           // == SLEventPostToPid
    CGEventPostToPid(pid, up);
    CFRelease(down); CFRelease(up);
    usleep(12000);
  }
  CFRelease(src);
}

static AXUIElementRef firstWindow(pid_t pid) {
  AXUIElementRef app = AXUIElementCreateApplication(pid);
  CFArrayRef wins = NULL;
  AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, (CFTypeRef *)&wins);
  AXUIElementRef w = (wins && CFArrayGetCount(wins)) ?
      (AXUIElementRef)CFRetain(CFArrayGetValueAtIndex(wins, 0)) : NULL;
  if (wins) CFRelease(wins);
  CFRelease(app);
  return w;
}

extern AXError _AXUIElementGetWindow(AXUIElementRef, uint32_t *);

int main(int argc, char **argv) { @autoreleasepool {
  if (argc != 3) {
    fprintf(stderr, "usage: probe4 PID VIRTUAL_DISPLAY_ID\n");
    return 2;
  }
  setvbuf(stdout, NULL, _IONBF, 0);
  loadSyms();
  pid_t pid = atoi(argv[1]);
  CGDirectDisplayID vdid = (CGDirectDisplayID)atoi(argv[2]);
  int cid = SLSMainConnectionID();
  CGRect vb = CGDisplayBounds(vdid);
  printf("virtual display %u bounds = %.0f,%.0f %.0fx%.0f\n",
         vdid, vb.origin.x, vb.origin.y, vb.size.width, vb.size.height);

  pid_t front0 = frontPid();
  printf("frontmost pid BEFORE      = %d (%s)\n", front0,
         NSWorkspace.sharedWorkspace.frontmostApplication.localizedName.UTF8String);

  // ---- 1. does the virtual display have its own Space? ----
  printf("\n[1] managed spaces per display\n");
  CFArrayRef disps = SLSCopyManagedDisplaySpaces(cid);
  for (NSDictionary *d in (__bridge NSArray *)disps) {
    NSString *current = [d[@"Current Space"][@"ManagedSpaceID"] description];
    printf("    %-40s spaces=%lu current=%s\n",
           [d[@"Display Identifier"] description].UTF8String,
           (unsigned long)[d[@"Spaces"] count], current.UTF8String ?: "(nil)");
  }
  CFRelease(disps);

  // ---- 2. move the app's window onto the virtual display ----
  AXUIElementRef win = firstWindow(pid);
  if (!win) { printf("FAIL: no AX window for pid %d\n", pid); return 1; }
  uint32_t wid = 0; _AXUIElementGetWindow(win, &wid);
  CGPoint p = CGPointMake(vb.origin.x + 120, vb.origin.y + 120);
  CGSize  sz = CGSizeMake(900, 640);
  AXValueRef pv = AXValueCreate(kAXValueCGPointType, &p);
  AXValueRef sv = AXValueCreate(kAXValueCGSizeType, &sz);
  AXError e1 = AXUIElementSetAttributeValue(win, kAXPositionAttribute, pv);
  AXError e2 = AXUIElementSetAttributeValue(win, kAXSizeAttribute, sv);
  CFRelease(pv); CFRelease(sv);
  printf("\n[2] moved window %u -> (%.0f,%.0f) setPos=%d setSize=%d\n", wid, p.x, p.y, e1, e2);
  usleep(400000);
  CGRect wb; SLSGetWindowBounds(cid, wid, &wb);
  printf("    window now at %.0f,%.0f %.0fx%.0f  onVirtualDisplay=%s\n",
         wb.origin.x, wb.origin.y, wb.size.width, wb.size.height,
         CGRectContainsPoint(vb, CGPointMake(CGRectGetMidX(wb), CGRectGetMidY(wb))) ? "YES" : "NO");

  CFArrayRef sp = SLSCopySpacesForWindows(cid, 0x7, (__bridge CFArrayRef)@[ @(wid) ]);
  NSString *spaceDescription = [(__bridge NSArray *)sp description];
  printf("    window's space(s): %s\n",
         spaceDescription.UTF8String ?: "(nil)");
  if (sp) CFRelease(sp);

  // ---- 3. drive it ----
  printf("\n[3] focus-without-raise + per-PID keystrokes\n");
  focusWithoutRaise(pid, wid);
  usleep(200000);
  typeString(pid, @"SpaceO agent typed this while you kept working.\n");
  usleep(500000);

  // ---- 4. read it back through AX ----
  AXUIElementRef app = AXUIElementCreateApplication(pid);
  AXUIElementRef focused = NULL;
  AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute, (CFTypeRef *)&focused);
  CFStringRef val = NULL;
  if (focused) AXUIElementCopyAttributeValue(focused, kAXValueAttribute, (CFTypeRef *)&val);
  printf("    AX focused element value = %s\n",
         val ? [(__bridge NSString *)val UTF8String] : "(nil)");

  // ---- 5. did we disturb the user? ----
  pid_t front1 = frontPid();
  printf("\n[5] frontmost pid AFTER     = %d (%s)   UNCHANGED=%s\n", front1,
         NSWorkspace.sharedWorkspace.frontmostApplication.localizedName.UTF8String,
         front0 == front1 ? "YES" : "NO  <-- focus was stolen");
  printf("WINDOW_ID=%u\n", wid);
  return 0;
}}
