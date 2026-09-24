// probe6.m — how many independent agent displays can we stand up at once?
// Creates N virtual displays, reports the resulting arrangement, then exits (all vanish).
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>

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
@end
@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)d;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)s;
@property(nonatomic, readonly) CGDirectDisplayID displayID;
@end

int main(int argc, char **argv) { @autoreleasepool {
  setvbuf(stdout, NULL, _IONBF, 0);
  int want = argc > 1 ? atoi(argv[1]) : 4;
  NSMutableArray *keep = [NSMutableArray array];
  for (int i = 0; i < want; i++) {
    CGVirtualDisplayDescriptor *d = [[objc_getClass("CGVirtualDisplayDescriptor") alloc] init];
    d.name = [NSString stringWithFormat:@"SpaceO Agent %d", i + 1];
    d.vendorID = 0x1AF2; d.productID = 0x0001; d.serialNum = 0x1000 + i;
    d.maxPixelsWide = 1440; d.maxPixelsHigh = 900;
    d.sizeInMillimeters = CGSizeMake(360, 225);
    d.redPrimary   = CGPointMake(0.68, 0.32);
    d.greenPrimary = CGPointMake(0.265, 0.69);
    d.bluePrimary  = CGPointMake(0.15, 0.06);
    d.whitePoint   = CGPointMake(0.3127, 0.3290);
    d.queue = dispatch_get_main_queue();
    CGVirtualDisplay *vd = [[objc_getClass("CGVirtualDisplay") alloc] initWithDescriptor:d];
    if (!vd) { printf("  display %d: CREATE FAILED\n", i + 1); break; }
    CGVirtualDisplaySettings *s = [[objc_getClass("CGVirtualDisplaySettings") alloc] init];
    s.modes = @[ [[objc_getClass("CGVirtualDisplayMode") alloc] initWithWidth:1440 height:900 refreshRate:60.0] ];
    s.hiDPI = 1;
    BOOL ok = [vd applySettings:s];
    printf("  display %d: id=%u applySettings=%d\n", i + 1, vd.displayID, ok);
    if (!ok) break;
    [keep addObject:vd];
    usleep(300000);
  }
  usleep(600000);
  uint32_t n = 0; CGDirectDisplayID ids[32];
  CGGetActiveDisplayList(32, ids, &n);
  printf("\nactive displays = %u\n", n);
  for (uint32_t i = 0; i < n; i++) {
    CGRect b = CGDisplayBounds(ids[i]);
    printf("   id=%-4u (%6.0f,%6.0f) %.0fx%.0f main=%d\n", ids[i],
           b.origin.x, b.origin.y, b.size.width, b.size.height, CGDisplayIsMain(ids[i]));
  }
  [keep removeAllObjects];   // tear every one back down
  printf("\npolling for removal:\n");
  for (int t = 0; t < 24; t++) {
    usleep(500000);
    CGGetActiveDisplayList(32, ids, &n);
    printf("  t=%4.1fs active=%u  [", (t + 1) * 0.5, n);
    for (uint32_t i = 0; i < n; i++) printf("%u ", ids[i]);
    printf("]\n");
    if (n <= 1) break;
  }
  return 0;
}}
