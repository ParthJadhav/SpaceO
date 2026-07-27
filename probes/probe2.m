// probe2.m — non-prompting symbol/capability inventory.
// Never call guessed private focus getters here: their macOS 27 ABI corrupted memory.
#import <Foundation/Foundation.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>

int main(void) { @autoreleasepool {
  setvbuf(stdout, NULL, _IONBF, 0);
  printf("AXIsProcessTrusted (accessibility) : %s\n", AXIsProcessTrusted() ? "YES" : "NO");
  printf("CGPreflightScreenCaptureAccess     : %s\n", CGPreflightScreenCaptureAccess() ? "YES" : "NO");

  void *sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
  printf("dlopen SkyLight                    : %s\n", sl ? "ok" : dlerror());

  const char *names[] = {"SLPSGetFrontProcess","SLPSGetKeyFocusProcess","SLPSGetTypingFocusProcess",
                         "SLEventPostToPid","SLPSPostEventRecordTo","SLPSStealKeyFocus",
                         "SLSSetAvoidsActivation","SLSSpaceCreate","SLSSpaceDestroy",
                         "SLSMoveWindowsToManagedSpace","SLSHWCaptureSpace","SLSSpaceSetAbsoluteLevel",
                         "SLSSetCursorRestrictionMode","SLSSetMouseFocusWindow","SLSSpaceSetFrontPSN"};
  printf("\n-- private symbol resolution --\n");
  for (unsigned i = 0; i < sizeof(names)/sizeof(*names); i++)
    printf("  %-32s %s\n", names[i], dlsym(sl, names[i]) ? "resolved" : "MISSING");

  printf("\n-- focus state --\n");
  printf("  intentionally not queried: private getter ABI is not safety-qualified\n");

  printf("\n-- displays --\n");
  uint32_t n = 0; CGDirectDisplayID ids[16];
  CGGetActiveDisplayList(16, ids, &n);
  for (uint32_t i = 0; i < n; i++)
    printf("  display %u  %ux%u  main=%d builtin=%d\n", ids[i],
           (unsigned)CGDisplayPixelsWide(ids[i]), (unsigned)CGDisplayPixelsHigh(ids[i]),
           CGDisplayIsMain(ids[i]), CGDisplayIsBuiltin(ids[i]));
  return 0;
}}
