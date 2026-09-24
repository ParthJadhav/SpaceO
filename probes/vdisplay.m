// vdisplay.m — create a headless virtual display via private CGVirtualDisplay and hold it
// until SIGTERM/SIGINT. The display vanishes the moment this process exits (the CGVirtualDisplay
// object owns it), so this is fully reversible.
//
//   ./vdisplay [width] [height] [hidpi]
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <signal.h>

@interface CGVirtualDisplayDescriptor : NSObject
@property(nonatomic, assign) unsigned int vendorID, productID, serialNum;
@property(nonatomic, strong) NSString *name;
@property(nonatomic, assign) CGSize sizeInMillimeters;
@property(nonatomic, assign) unsigned int maxPixelsWide, maxPixelsHigh;
@property(nonatomic, assign) CGPoint redPrimary, greenPrimary, bluePrimary, whitePoint;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, copy)   void (^terminationHandler)(id a, id b);
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)w height:(unsigned int)h refreshRate:(double)r;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic, strong) NSArray *modes;
@property(nonatomic, assign) unsigned int hiDPI;
@property(nonatomic, assign) unsigned int rotation;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)d;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)s;
@property(nonatomic, readonly) CGDirectDisplayID displayID;
@end

static CGVirtualDisplay *g_display = nil;   // strong ref keeps the display alive
static void bye(int sig) { g_display = nil; _exit(0); }

int main(int argc, char **argv) { @autoreleasepool {
  setvbuf(stdout, NULL, _IONBF, 0);
  unsigned w = argc > 1 ? atoi(argv[1]) : 1920;
  unsigned h = argc > 2 ? atoi(argv[2]) : 1080;
  unsigned hidpi = argc > 3 ? atoi(argv[3]) : 1;

  signal(SIGTERM, bye); signal(SIGINT, bye);

  CGVirtualDisplayDescriptor *desc = [[objc_getClass("CGVirtualDisplayDescriptor") alloc] init];
  desc.name              = @"SpaceO Agent Display";
  desc.vendorID          = 0x1AF2;      // arbitrary; identifies our virtual panel
  desc.productID         = 0x0001;
  desc.serialNum         = 0x0001;
  desc.maxPixelsWide     = w;
  desc.maxPixelsHigh     = h;
  desc.sizeInMillimeters = CGSizeMake(w / 4.0, h / 4.0);   // ~101 dpi
  desc.redPrimary        = CGPointMake(0.6800, 0.3200);
  desc.greenPrimary      = CGPointMake(0.2650, 0.6900);
  desc.bluePrimary       = CGPointMake(0.1500, 0.0600);
  desc.whitePoint        = CGPointMake(0.3127, 0.3290);
  desc.queue             = dispatch_get_main_queue();
  desc.terminationHandler = ^(id a, id b) { fprintf(stderr, "[vdisplay] terminated by system\n"); };

  g_display = [[objc_getClass("CGVirtualDisplay") alloc] initWithDescriptor:desc];
  if (!g_display) { fprintf(stderr, "FAIL: could not create CGVirtualDisplay\n"); return 1; }

  CGVirtualDisplaySettings *set = [[objc_getClass("CGVirtualDisplaySettings") alloc] init];
  CGVirtualDisplayMode *mode = [[objc_getClass("CGVirtualDisplayMode") alloc]
                                  initWithWidth:w height:h refreshRate:60.0];
  set.modes  = @[ mode ];
  set.hiDPI  = hidpi;
  if (![g_display applySettings:set]) { fprintf(stderr, "FAIL: applySettings\n"); return 1; }

  CGDirectDisplayID did = g_display.displayID;
  CGRect b = CGDisplayBounds(did);
  printf("VDISPLAY_ID=%u\n", did);
  printf("VDISPLAY_BOUNDS=%.0f,%.0f,%.0f,%.0f\n", b.origin.x, b.origin.y, b.size.width, b.size.height);
  printf("VDISPLAY_PIXELS=%zux%zu\n", CGDisplayPixelsWide(did), CGDisplayPixelsHigh(did));
  printf("READY\n");

  [[NSRunLoop currentRunLoop] run];
  return 0;
}}
