// probe3.m — introspect CGVirtualDisplay* on this macOS build. Creates nothing.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static void dumpClass(const char *name) {
  Class c = objc_getClass(name);
  printf("\n=== %s === %s\n", name, c ? "" : "  << NOT PRESENT >>");
  if (!c) return;
  unsigned n = 0;
  Method *ms = class_copyMethodList(c, &n);
  for (unsigned i = 0; i < n; i++) {
    char *t = method_copyReturnType(ms[i]);
    printf("  -%-52s ret=%s argtypes=", sel_getName(method_getName(ms[i])), t);
    unsigned na = method_getNumberOfArguments(ms[i]);
    for (unsigned a = 2; a < na; a++) { char b[128]; method_getArgumentType(ms[i], a, b, sizeof b); printf("%s ", b); }
    printf("\n"); free(t);
  }
  free(ms);
  unsigned np = 0;
  objc_property_t *ps = class_copyPropertyList(c, &np);
  for (unsigned i = 0; i < np; i++)
    printf("  @property %-28s %s\n", property_getName(ps[i]), property_getAttributes(ps[i]));
  free(ps);
}

int main(void) { @autoreleasepool {
  setvbuf(stdout, NULL, _IONBF, 0);
  dumpClass("CGVirtualDisplayDescriptor");
  dumpClass("CGVirtualDisplayMode");
  dumpClass("CGVirtualDisplaySettings");
  dumpClass("CGVirtualDisplay");
  return 0;
}}
