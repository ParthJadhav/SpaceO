//
//  SpaceOPrivate.m
//
#import "SpaceOPrivate.h"
#import <dlfcn.h>
#import <math.h>
#import <objc/runtime.h>
#import <sys/sysctl.h>

// GetProcessForPID/GetProcessPID are soft-deprecated but remain the only way to obtain the
// ProcessSerialNumber that SLPSPostEventRecordTo requires. There is no replacement.
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#pragma mark - Lazy symbol resolution

typedef int CGSConnectionID;

static CGSConnectionID (*p_SLSMainConnectionID)(void);
static CFArrayRef (*p_SLSCopyManagedDisplaySpaces)(CGSConnectionID);
static CFArrayRef (*p_SLSCopySpacesForWindows)(CGSConnectionID, int, CFArrayRef);
static uint64_t   (*p_SLSGetActiveSpace)(CGSConnectionID);
static OSStatus   (*p_SLPSPostEventRecordTo)(ProcessSerialNumber *, uint8_t *);
static CGError    (*p_SLSGetWindowBounds)(CGSConnectionID, uint32_t, CGRect *);
static AXError    (*p_AXUIElementGetWindow)(AXUIElementRef, uint32_t *);
static void       (*p_CGEventPostToPid)(pid_t, CGEventRef);

static NSMutableArray<NSString *> *g_missing = nil;

#pragma mark - Evidence-backed host qualification

@implementation SPOHostTuple

- (instancetype)initWithOperatingSystemMajor:(NSInteger)major
                                       minor:(NSInteger)minor
                                       patch:(NSInteger)patch
                                 darwinBuild:(NSString *)darwinBuild
                                architecture:(NSString *)architecture
                           evidenceReference:(nullable NSString *)evidenceReference {
    self = [super init];
    if (!self) return nil;
    _operatingSystemMajor = major;
    _operatingSystemMinor = minor;
    _operatingSystemPatch = patch;
    _darwinBuild = [darwinBuild copy];
    _architecture = [architecture copy];
    _evidenceReference = [evidenceReference copy];
    return self;
}

@end

@implementation SPOHostQualification

- (instancetype)initWithCapability:(SPOCapability)capability
                              host:(SPOHostTuple *)host {
    self = [super init];
    if (!self) return nil;
    _capability = capability;
    _host = host;
    return self;
}

@end

static NSString *SPODarwinBuild(void) {
    size_t size = 0;
    if (sysctlbyname("kern.osversion", NULL, &size, NULL, 0) != 0 || size < 2)
        return @"unknown";
    char *buffer = calloc(size, sizeof(char));
    if (!buffer) return @"unknown";
    NSString *result = @"unknown";
    if (sysctlbyname("kern.osversion", buffer, &size, NULL, 0) == 0) {
        NSString *value = [NSString stringWithUTF8String:buffer];
        if (value.length > 0) result = value;
    }
    free(buffer);
    return result;
}

static NSString *SPOProcessArchitecture(void) {
#if defined(__arm64__) || defined(__aarch64__)
    return @"arm64";
#elif defined(__x86_64__)
    return @"x86_64";
#else
    return @"unknown";
#endif
}

SPOHostTuple *SPOCurrentHostTuple(void) {
    static SPOHostTuple *host;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
        host = [[SPOHostTuple alloc]
            initWithOperatingSystemMajor:version.majorVersion
            minor:version.minorVersion
            patch:version.patchVersion
            darwinBuild:SPODarwinBuild()
            architecture:SPOProcessArchitecture()
            evidenceReference:nil];
    });
    return host;
}

NSString *SPOHostTupleDescription(SPOHostTuple *host) {
    return [NSString stringWithFormat:@"macOS %ld.%ld.%ld / Darwin build %@ / %@",
            (long)host.operatingSystemMajor,
            (long)host.operatingSystemMinor,
            (long)host.operatingSystemPatch,
            host.darwinBuild,
            host.architecture];
}

NSArray<SPOHostQualification *> *SPOQualifiedHostRegistry(void) {
    // Entries are intentionally capability-specific. In particular, the focus-record layout is
    // not enabled by the successful display/input regression: direct per-PID delivery does not
    // require that global input-route mutation.
    static NSArray<SPOHostQualification *> *registry;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SPOHostTuple *macOS27DevelopmentHost = [[SPOHostTuple alloc]
            initWithOperatingSystemMajor:27
            minor:0
            patch:0
            darwinBuild:@"26A5368g"
            architecture:@"arm64"
            evidenceReference:
                @"docs/qualification/macos-27.0-26A5368g-arm64.md"];
        registry = @[
            [[SPOHostQualification alloc]
                initWithCapability:SPOCapabilityVirtualDisplay
                host:macOS27DevelopmentHost],
            [[SPOHostQualification alloc]
                initWithCapability:SPOCapabilitySpaceQuery
                host:macOS27DevelopmentHost],
            [[SPOHostQualification alloc]
                initWithCapability:SPOCapabilityPerPIDEvents
                host:macOS27DevelopmentHost],
            [[SPOHostQualification alloc]
                initWithCapability:SPOCapabilityAXWindowID
                host:macOS27DevelopmentHost],
        ];
    });
    return registry;
}

static BOOL SPOHasEvidenceReference(SPOHostTuple *host) {
    NSString *reference = [host.evidenceReference
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return reference.length > 0;
}

static BOOL SPOHostTuplesMatch(SPOHostTuple *observed, SPOHostTuple *qualified) {
    return observed.operatingSystemMajor == qualified.operatingSystemMajor
        && observed.operatingSystemMinor == qualified.operatingSystemMinor
        && observed.operatingSystemPatch == qualified.operatingSystemPatch
        && [observed.darwinBuild isEqualToString:qualified.darwinBuild]
        && [observed.architecture isEqualToString:qualified.architecture];
}

BOOL SPOHostIsQualifiedForCapability(
    SPOCapability cap,
    SPOHostTuple *host,
    NSArray<SPOHostQualification *> *registry
) {
    if (cap < 0 || cap >= SPOCapabilityCount || !host) return NO;
    for (SPOHostQualification *entry in registry) {
        if (![entry isKindOfClass:SPOHostQualification.class]) continue;
        if (entry.capability != cap || !SPOHasEvidenceReference(entry.host)) continue;
        if (SPOHostTuplesMatch(host, entry.host)) return YES;
    }
    return NO;
}

BOOL SPOCapabilityAllowedForHost(
    SPOCapability cap,
    SPOHostTuple *host,
    NSArray<SPOHostQualification *> *registry,
    BOOL requiredBehaviorPresent
) {
    return requiredBehaviorPresent
        && SPOHostIsQualifiedForCapability(cap, host, registry);
}

static void *resolve(void *handle, const char *name) {
    void *sym = dlsym(handle, name);
    if (!sym) [g_missing addObject:@(name)];
    return sym;
}

static void SPOLoad(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_missing = [NSMutableArray array];

        void *sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
                           RTLD_LAZY | RTLD_LOCAL);
        if (!sky) {
            [g_missing addObject:@"SkyLight.framework"];
        } else {
            p_SLSMainConnectionID         = resolve(sky, "SLSMainConnectionID");
            p_SLSCopyManagedDisplaySpaces = resolve(sky, "SLSCopyManagedDisplaySpaces");
            p_SLSCopySpacesForWindows     = resolve(sky, "SLSCopySpacesForWindows");
            p_SLSGetActiveSpace           = resolve(sky, "SLSGetActiveSpace");
            p_SLPSPostEventRecordTo       = resolve(sky, "SLPSPostEventRecordTo");
            p_SLSGetWindowBounds          = resolve(sky, "SLSGetWindowBounds");
        }

        // _AXUIElementGetWindow lives in the (public) HIServices sub-framework but is not declared.
        void *self_handle = dlopen(NULL, RTLD_LAZY);
        p_AXUIElementGetWindow = resolve(self_handle, "_AXUIElementGetWindow");
        p_CGEventPostToPid = (void (*)(pid_t, CGEventRef))
            resolve(self_handle, "CGEventPostToPid");

        // The virtual-display classes are ObjC, so presence is a class lookup, not a dlsym.
        const char *classes[] = { "CGVirtualDisplay", "CGVirtualDisplayDescriptor",
                                  "CGVirtualDisplayMode", "CGVirtualDisplaySettings" };
        for (size_t i = 0; i < sizeof(classes) / sizeof(*classes); i++)
            if (!objc_getClass(classes[i])) [g_missing addObject:@(classes[i])];
    });
}

#pragma mark - Capability gate

static BOOL SPORequiredBehaviorPresent(SPOCapability cap) {
    switch (cap) {
        case SPOCapabilityVirtualDisplay:
            return objc_getClass("CGVirtualDisplay") != Nil
                && objc_getClass("CGVirtualDisplayDescriptor") != Nil
                && objc_getClass("CGVirtualDisplayMode") != Nil
                && objc_getClass("CGVirtualDisplaySettings") != Nil;
        case SPOCapabilityFocusWithoutRaise:
            return p_SLPSPostEventRecordTo != NULL;
        case SPOCapabilitySpaceQuery:
            return p_SLSMainConnectionID != NULL
                && p_SLSCopyManagedDisplaySpaces != NULL
                && p_SLSCopySpacesForWindows != NULL
                && p_SLSGetActiveSpace != NULL
                && p_SLSGetWindowBounds != NULL;
        case SPOCapabilityPerPIDEvents:
            return p_CGEventPostToPid != NULL;
        case SPOCapabilityAXWindowID:
            return p_AXUIElementGetWindow != NULL;
        default:
            return NO;
    }
}

BOOL SPOCapabilityAvailable(SPOCapability cap) {
    SPOLoad();
    return SPOCapabilityAllowedForHost(
        cap,
        SPOCurrentHostTuple(),
        SPOQualifiedHostRegistry(),
        SPORequiredBehaviorPresent(cap)
    );
}

NSString *SPOCapabilityName(SPOCapability cap) {
    switch (cap) {
        case SPOCapabilityVirtualDisplay:    return @"virtual-display";
        case SPOCapabilityFocusWithoutRaise: return @"focus-without-raise";
        case SPOCapabilitySpaceQuery:        return @"space-query";
        case SPOCapabilityPerPIDEvents:      return @"per-pid-events";
        case SPOCapabilityAXWindowID:        return @"ax-window-id";
        default:                             return @"unknown";
    }
}

NSString *_Nullable SPOCapabilityUnavailableReason(SPOCapability cap) {
    SPOLoad();
    SPOHostTuple *current = SPOCurrentHostTuple();
    NSArray<SPOHostQualification *> *registry = SPOQualifiedHostRegistry();
    if (!SPOHostIsQualifiedForCapability(cap, current, registry)) {
        NSMutableArray<NSString *> *qualified = [NSMutableArray array];
        for (SPOHostQualification *entry in registry) {
            if (entry.capability != cap || !SPOHasEvidenceReference(entry.host)) continue;
            [qualified addObject:SPOHostTupleDescription(entry.host)];
        }
        NSString *currentDescription = SPOHostTupleDescription(current);
        if (qualified.count == 0) {
            return [NSString stringWithFormat:
                @"unsupported host for %@: no evidence-backed qualified tuples are registered; "
                 "current host is %@. Symbol/class presence is insufficient. Validate this exact "
                 "tuple in a disposable login and record the evidence before enabling it.",
                SPOCapabilityName(cap), currentDescription];
        }
        return [NSString stringWithFormat:
            @"unsupported host for %@: current host %@ is not an exact match for an "
             "evidence-backed tuple (%@). Symbol/class presence is insufficient.",
            SPOCapabilityName(cap),
            currentDescription,
            [qualified componentsJoinedByString:@"; "]];
    }
    if (!SPORequiredBehaviorPresent(cap)) {
        return [NSString stringWithFormat:
            @"qualified host %@ is missing a required symbol or Objective-C class for %@",
            SPOHostTupleDescription(current), SPOCapabilityName(cap)];
    }
    return nil;
}

NSArray<NSString *> *SPOMissingSymbols(void) {
    SPOLoad();
    return [g_missing copy];
}

BOOL SPOBuiltWithARC(void) {
#if __has_feature(objc_arc)
    return YES;
#else
    return NO;
#endif
}

#pragma mark - Virtual display class surface

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, assign) unsigned int vendorID, productID, serialNum;
@property (nonatomic, strong) NSString *name;
@property (nonatomic, assign) CGSize sizeInMillimeters;
@property (nonatomic, assign) unsigned int maxPixelsWide, maxPixelsHigh;
@property (nonatomic, assign) CGPoint redPrimary, greenPrimary, bluePrimary, whitePoint;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, copy)   void (^terminationHandler)(id a, id b);
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

@implementation SPOVirtualDisplay {
    CGVirtualDisplay *_display;      // strong ref *is* the display's lifetime
    dispatch_queue_t _queue;         // must outlive _display
    CGDirectDisplayID _displayID;
}

- (nullable instancetype)initWithName:(NSString *)name
                                width:(uint32_t)width
                               height:(uint32_t)height
                                hiDPI:(BOOL)hiDPI {
    self = [super init];
    if (!self) return nil;
    if (!SPOCapabilityAvailable(SPOCapabilityVirtualDisplay)) return nil;
    if (width == 0 || height == 0) return nil;

    Class descClass = objc_getClass("CGVirtualDisplayDescriptor");
    Class modeClass = objc_getClass("CGVirtualDisplayMode");
    Class setClass  = objc_getClass("CGVirtualDisplaySettings");
    Class dispClass = objc_getClass("CGVirtualDisplay");

    CGVirtualDisplayDescriptor *desc = [[descClass alloc] init];
    desc.name              = name;
    desc.vendorID          = 0x1AF2;                 // identifies a SpaceO stage
    desc.productID         = 0x0001;
    desc.serialNum         = (unsigned int)(name.hash & 0xFFFFFFFF);
    desc.maxPixelsWide     = width;
    desc.maxPixelsHigh     = height;
    desc.sizeInMillimeters = CGSizeMake(width / 4.0, height / 4.0);   // ~101 dpi
    desc.redPrimary        = CGPointMake(0.6800, 0.3200);
    desc.greenPrimary      = CGPointMake(0.2650, 0.6900);
    desc.bluePrimary       = CGPointMake(0.1500, 0.0600);
    desc.whitePoint        = CGPointMake(0.3127, 0.3290);

    // A private serial queue, NOT the main queue.
    //
    // CoreGraphics publishes the display's lifecycle messages (it is live, here are your
    // bounds, it has been retired) on this queue. Binding it to the main queue makes display
    // creation and teardown silently depend on the *caller* running a main run loop — which
    // an XCTest case or a CLI one-shot does not. Symptom when we got this wrong: the display
    // registered but never reported bounds, and never went away on release.
    _queue = dispatch_queue_create("dev.spaceo.virtual-display", DISPATCH_QUEUE_SERIAL);
    desc.queue = _queue;

    _display = [[dispClass alloc] initWithDescriptor:desc];
    if (!_display) return nil;

    CGVirtualDisplaySettings *settings = [[setClass alloc] init];
    settings.modes = @[ [[modeClass alloc] initWithWidth:width height:height refreshRate:60.0] ];
    settings.hiDPI = hiDPI ? 1 : 0;
    if (![_display applySettings:settings]) { _display = nil; return nil; }

    _displayID = _display.displayID;
    return self;
}

- (CGDirectDisplayID)displayID { return _displayID; }
- (BOOL)valid                  { return _display != nil && _displayID != 0; }
- (CGRect)bounds               { return _displayID ? CGDisplayBounds(_displayID) : CGRectZero; }
- (void)invalidate             { _display = nil; _displayID = 0; _queue = nil; }
- (void)dealloc                { _display = nil; _queue = nil; }

@end

#pragma mark - Space graph

static NSString *_Nullable UUIDStringForDisplay(CGDirectDisplayID did) {
    CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(did);
    if (!uuid) return nil;
    CFStringRef s = CFUUIDCreateString(kCFAllocatorDefault, uuid);
    NSString *result = (__bridge_transfer NSString *)s;
    CFRelease(uuid);
    return result;
}

NSArray *_Nullable SPOManagedDisplaySpaces(void) {
    SPOLoad();
    if (!SPOCapabilityAvailable(SPOCapabilitySpaceQuery)) return nil;
    if (!p_SLSMainConnectionID || !p_SLSCopyManagedDisplaySpaces) return nil;
    CFArrayRef raw = p_SLSCopyManagedDisplaySpaces(p_SLSMainConnectionID());
    if (!raw) return nil;
    if (CFGetTypeID(raw) != CFArrayGetTypeID()) {
        CFRelease(raw);
        return nil;
    }
    return (__bridge_transfer NSArray *)raw;
}

NSArray<NSNumber *> *_Nullable SPOSpacesForDisplay(CGDirectDisplayID displayID) {
    NSArray *displays = SPOManagedDisplaySpaces();
    if (!displays) return nil;
    NSString *want = UUIDStringForDisplay(displayID);
    for (id value in displays) {
        if (![value isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *d = value;
        id rawIdent = d[@"Display Identifier"];
        NSString *ident = [rawIdent isKindOfClass:NSString.class] ? rawIdent : nil;
        BOOL match = (want && [ident isEqualToString:want])
                  || (displays.count == 1)
                  || [ident isEqualToString:@"Main"];
        if (!match) continue;
        NSMutableArray<NSNumber *> *out = [NSMutableArray array];
        id rawSpaces = d[@"Spaces"];
        if (![rawSpaces isKindOfClass:NSArray.class]) return out;
        for (id spaceValue in (NSArray *)rawSpaces) {
            if (![spaceValue isKindOfClass:NSDictionary.class]) continue;
            id sid = ((NSDictionary *)spaceValue)[@"ManagedSpaceID"];
            if ([sid isKindOfClass:NSNumber.class]) [out addObject:sid];
        }
        return out;
    }
    return @[];
}

NSArray<NSNumber *> *_Nullable SPOSpacesForWindow(uint32_t windowID) {
    SPOLoad();
    if (!SPOCapabilityAvailable(SPOCapabilitySpaceQuery)) return nil;
    if (!p_SLSMainConnectionID || !p_SLSCopySpacesForWindows) return nil;
    CFArrayRef raw = p_SLSCopySpacesForWindows(p_SLSMainConnectionID(), 0x7,
                                               (__bridge CFArrayRef)@[ @(windowID) ]);
    if (!raw) return nil;
    if (CFGetTypeID(raw) != CFArrayGetTypeID()) {
        CFRelease(raw);
        return nil;
    }
    NSArray *values = (__bridge_transfer NSArray *)raw;
    NSMutableArray<NSNumber *> *out = [NSMutableArray array];
    for (id value in values) {
        if ([value isKindOfClass:NSNumber.class]) [out addObject:value];
    }
    return out;
}

uint64_t SPOActiveSpace(void) {
    SPOLoad();
    if (!SPOCapabilityAvailable(SPOCapabilitySpaceQuery)) return 0;
    if (!p_SLSMainConnectionID || !p_SLSGetActiveSpace) return 0;
    return p_SLSGetActiveSpace(p_SLSMainConnectionID());
}

#pragma mark - Focus routing

SPOFocusResult SPOFocusWithoutRaiseResult(pid_t pid, uint32_t windowID) {
    SPOLoad();
    // Do not rely on Swift callers having checked the capability. This C function is public to
    // the package and validates the runtime symbol at the mutation boundary itself.
    if (!SPOCapabilityAvailable(SPOCapabilityFocusWithoutRaise))
        return SPOFocusResultNotAttempted;
    if (!p_SLPSPostEventRecordTo) return SPOFocusResultNotAttempted;

    ProcessSerialNumber psn = {0, kNoProcess};
    if (GetProcessForPID(pid, &psn) != noErr) return SPOFocusResultNotAttempted;

    // Record 1: "you are now the active app for input routing".
    // Crucially this is NOT SLPSSetFrontProcessWithOptions, so nothing is raised and the
    // user is not dragged to this app's Space.
    uint8_t activate[0xf8] = {0};
    activate[0x04] = 0xf8;
    activate[0x08] = 0x0d;
    memcpy(activate + 0x3c, &windowID, sizeof windowID);
    memset(activate + 0x20, 0xff, 0x10);
    activate[0x8a] = 0x01;
    if (p_SLPSPostEventRecordTo(&psn, activate) != noErr)
        return SPOFocusResultFailedAfterActivationRecord;

    // Record 2 & 3: make that specific window the key window within the app.
    uint8_t key[0xf8] = {0};
    key[0x04] = 0xf8;
    key[0x3a] = 0x10;
    memcpy(key + 0x3c, &windowID, sizeof windowID);
    memset(key + 0x20, 0xff, 0x10);
    key[0x08] = 0x01;
    if (p_SLPSPostEventRecordTo(&psn, key) != noErr)
        return SPOFocusResultFailedAfterKeyDownRecord;
    key[0x08] = 0x02;
    if (p_SLPSPostEventRecordTo(&psn, key) != noErr)
        return SPOFocusResultFailedAfterKeyUpRecord;

    return SPOFocusResultSucceeded;
}

BOOL SPOFocusWithoutRaise(pid_t pid, uint32_t windowID) {
    return SPOFocusWithoutRaiseResult(pid, windowID) == SPOFocusResultSucceeded;
}

pid_t SPOFrontProcessPID(void) {
    // Retained as an ABI-compatible stub for existing package clients. A symbol resolving via
    // dlsym does not prove its private calling convention, and the product has a public AppKit
    // source for the frontmost application. Do not query another guessed ProcessSerialNumber ABI.
    return 0;
}

#pragma mark - Window geometry

BOOL SPOWindowBounds(uint32_t windowID, CGRect *outBounds) {
    SPOLoad();
    if (!SPOCapabilityAvailable(SPOCapabilitySpaceQuery)) return NO;
    if (!p_SLSMainConnectionID || !p_SLSGetWindowBounds || !outBounds) return NO;
    if (p_SLSGetWindowBounds(p_SLSMainConnectionID(), windowID, outBounds)
        != kCGErrorSuccess) return NO;
    return isfinite(outBounds->origin.x) && isfinite(outBounds->origin.y)
        && isfinite(outBounds->size.width) && isfinite(outBounds->size.height)
        && outBounds->size.width >= 0 && outBounds->size.height >= 0;
}

uint32_t SPOWindowIDForAXElement(AXUIElementRef element) {
    SPOLoad();
    if (!SPOCapabilityAvailable(SPOCapabilityAXWindowID)) return 0;
    if (!p_AXUIElementGetWindow || !element) return 0;
    uint32_t wid = 0;
    if (p_AXUIElementGetWindow(element, &wid) != kAXErrorSuccess) return 0;
    return wid;
}

#pragma mark - Per-process event delivery

BOOL SPOPostEventToPID(pid_t pid, CGEventRef event) {
    SPOLoad();
    if (!event || pid <= 0) return NO;
    if (!SPOCapabilityAvailable(SPOCapabilityPerPIDEvents)) return NO;
    if (!p_CGEventPostToPid) return NO;
    p_CGEventPostToPid(pid, event);
    return YES;
}
