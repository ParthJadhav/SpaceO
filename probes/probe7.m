// probe7.m — does CGConfigureDisplayOrigin pin a virtual display so it can never be retired?
//
//   ./probe7 0   create, release, poll        (baseline)
//   ./probe7 1   create, PARK, release, poll  (suspect)
//   ./probe7 2   create, PARK, unpark via CGRestorePermanentDisplayConfiguration, release, poll
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, assign) unsigned int vendorID, productID, serialNum;
@property (nonatomic, strong) NSString *name;
@property (nonatomic, assign) CGSize sizeInMillimeters;
@property (nonatomic, assign) unsigned int maxPixelsWide, maxPixelsHigh;
@property (nonatomic, assign) CGPoint redPrimary, greenPrimary, bluePrimary, whitePoint;
@property (nonatomic, strong) dispatch_queue_t queue;
@end
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)w height:(unsigned int)h refreshRate:(double)r;
@end
@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic, strong) NSArray *modes;
@property (nonatomic, assign) unsigned int hiDPI;
@end
@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)d;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)s;
@property (nonatomic, readonly) CGDirectDisplayID displayID;
@end

static BOOL present(CGDirectDisplayID want) {
    CGDirectDisplayID ids[32]; uint32_t n = 0;
    CGGetActiveDisplayList(32, ids, &n);
    for (uint32_t i = 0; i < n; i++) if (ids[i] == want) return YES;
    return NO;
}

int main(int argc, char **argv) { @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0);
    int mode = argc > 1 ? atoi(argv[1]) : 0;
    printf("mode %d (%s)\n", mode,
           mode == 0 ? "no parking" : mode == 1 ? "park" : "park + restore");

    CGDirectDisplayID did = 0;
    @autoreleasepool {
        CGVirtualDisplayDescriptor *d = [[objc_getClass("CGVirtualDisplayDescriptor") alloc] init];
        d.name = @"probe7"; d.vendorID = 0x1AF2; d.productID = 1; d.serialNum = 7;
        d.maxPixelsWide = 1280; d.maxPixelsHigh = 800;
        d.sizeInMillimeters = CGSizeMake(320, 200);
        d.redPrimary = CGPointMake(0.68, 0.32);
        d.greenPrimary = CGPointMake(0.265, 0.69);
        d.bluePrimary = CGPointMake(0.15, 0.06);
        d.whitePoint = CGPointMake(0.3127, 0.3290);
        d.queue = dispatch_queue_create("probe7", DISPATCH_QUEUE_SERIAL);

        CGVirtualDisplay *vd = [[objc_getClass("CGVirtualDisplay") alloc] initWithDescriptor:d];
        CGVirtualDisplaySettings *s = [[objc_getClass("CGVirtualDisplaySettings") alloc] init];
        s.modes = @[ [[objc_getClass("CGVirtualDisplayMode") alloc] initWithWidth:1280 height:800 refreshRate:60.0] ];
        s.hiDPI = 1;
        if (![vd applySettings:s]) { printf("applySettings FAILED\n"); return 1; }
        did = vd.displayID;
        CGRect b = CGDisplayBounds(did);
        printf("created display %u at (%.0f,%.0f)\n", did, b.origin.x, b.origin.y);

        if (mode >= 1) {
            CGDisplayConfigRef cfg;
            CGBeginDisplayConfiguration(&cfg);
            CGConfigureDisplayOrigin(cfg, did, 12000, 9000);
            CGError e = CGCompleteDisplayConfiguration(cfg, kCGConfigureForAppOnly);
            usleep(800000);
            b = CGDisplayBounds(did);
            printf("parked (err=%d) -> (%.0f,%.0f)\n", e, b.origin.x, b.origin.y);
        }
        if (mode >= 2) {
            CGRestorePermanentDisplayConfiguration();
            usleep(800000);
            b = CGDisplayBounds(did);
            printf("restored -> (%.0f,%.0f)\n", b.origin.x, b.origin.y);
        }
        vd = nil;   // release
    }

    printf("released; polling:\n");
    BOOL leaked = YES;
    for (int t = 0; t < 20; t++) {
        usleep(500000);
        if (!present(did)) { printf("  gone at t=%.1fs   RESULT: OK\n", (t + 1) * 0.5); leaked = NO; break; }
    }
    if (leaked) printf("  still present after 10s   RESULT: LEAKED\n");

    // Does a pinned display poison the subsystem for subsequent displays in this process?
    printf("aftermath: creating a second display...\n");
    @autoreleasepool {
        CGVirtualDisplayDescriptor *d = [[objc_getClass("CGVirtualDisplayDescriptor") alloc] init];
        d.name = @"probe7-second"; d.vendorID = 0x1AF2; d.productID = 1; d.serialNum = 77;
        d.maxPixelsWide = 1024; d.maxPixelsHigh = 768;
        d.sizeInMillimeters = CGSizeMake(256, 192);
        d.redPrimary = CGPointMake(0.68, 0.32);
        d.greenPrimary = CGPointMake(0.265, 0.69);
        d.bluePrimary = CGPointMake(0.15, 0.06);
        d.whitePoint = CGPointMake(0.3127, 0.3290);
        d.queue = dispatch_queue_create("probe7b", DISPATCH_QUEUE_SERIAL);
        CGVirtualDisplay *vd = [[objc_getClass("CGVirtualDisplay") alloc] initWithDescriptor:d];
        CGVirtualDisplaySettings *s = [[objc_getClass("CGVirtualDisplaySettings") alloc] init];
        s.modes = @[ [[objc_getClass("CGVirtualDisplayMode") alloc] initWithWidth:1024 height:768 refreshRate:60.0] ];
        s.hiDPI = 1;
        BOOL ok = [vd applySettings:s];
        CGRect b = CGRectZero;
        for (int t = 0; t < 40 && CGRectIsEmpty(b); t++) { usleep(50000); b = CGDisplayBounds(vd.displayID); }
        printf("  second display id=%u applySettings=%d bounds=%.0fx%.0f  %s\n",
               vd.displayID, ok, b.size.width, b.size.height,
               CGRectIsEmpty(b) ? "POISONED (no bounds)" : "healthy");
        vd = nil;
    }
    return leaked ? 1 : 0;
}}
