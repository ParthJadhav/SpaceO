// probe5.m — can we park the agent display far from the user's display so the
// cursor can't casually walk onto it? Tries CGConfigureDisplayOrigin with a big gap.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

static void dump(const char *tag) {
  uint32_t n = 0; CGDirectDisplayID ids[16];
  CGGetActiveDisplayList(16, ids, &n);
  printf("%s\n", tag);
  for (uint32_t i = 0; i < n; i++) {
    CGRect b = CGDisplayBounds(ids[i]);
    printf("   id=%-4u origin=(%7.0f,%7.0f) size=%.0fx%.0f main=%d\n",
           ids[i], b.origin.x, b.origin.y, b.size.width, b.size.height, CGDisplayIsMain(ids[i]));
  }
}

int main(int argc, char **argv) { @autoreleasepool {
  if (argc != 4) {
    fprintf(stderr, "usage: probe5 DISPLAY_ID X Y\n");
    return 2;
  }
  setvbuf(stdout, NULL, _IONBF, 0);
  CGDirectDisplayID target = (CGDirectDisplayID)atoi(argv[1]);
  int32_t x = atoi(argv[2]), y = atoi(argv[3]);
  dump("BEFORE:");
  CGDisplayConfigRef cfg;
  CGError e = CGBeginDisplayConfiguration(&cfg);
  printf("\nCGBeginDisplayConfiguration = %d\n", e);
  e = CGConfigureDisplayOrigin(cfg, target, x, y);
  printf("CGConfigureDisplayOrigin(%u, %d, %d) = %d\n", target, x, y, e);
  e = CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
  printf("CGCompleteDisplayConfiguration = %d\n\n", e);
  usleep(800000);
  dump("AFTER:");
  return 0;
}}
