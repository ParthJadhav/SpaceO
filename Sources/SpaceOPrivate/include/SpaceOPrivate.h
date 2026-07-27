//
//  SpaceOPrivate.h
//  The one place in SpaceO that touches private macOS API.
//
//  Every symbol is resolved lazily with dlsym against SkyLight.framework / CoreGraphics.
//  This detects missing symbols, not ABI or behavioral compatibility. Higher-level lifecycle,
//  display-graph, and input-route checks remain responsible for validating each mutation.
//
#ifndef SPACEO_PRIVATE_H
#define SPACEO_PRIVATE_H

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ApplicationServices/ApplicationServices.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Capability gate

typedef NS_ENUM(NSInteger, SPOCapability) {
    /// CGVirtualDisplay + descriptor/mode/settings classes (the agent's stage).
    SPOCapabilityVirtualDisplay = 0,
    /// SLPSPostEventRecordTo — flip input routing without raising a window.
    SPOCapabilityFocusWithoutRaise,
    /// SLSCopyManagedDisplaySpaces & friends — read the Space graph.
    SPOCapabilitySpaceQuery,
    /// CGEventPostToPid — per-process event delivery (public, but we verify it anyway).
    SPOCapabilityPerPIDEvents,
    /// _AXUIElementGetWindow — map an AX element to a CGWindowID.
    SPOCapabilityAXWindowID,
    SPOCapabilityCount
};

/// YES when the classes or symbols required by the operation exist on this runtime.
BOOL SPOCapabilityAvailable(SPOCapability cap);
NSString *SPOCapabilityName(SPOCapability cap);
/// Names of every symbol we wanted but could not resolve. Empty does not imply ABI compatibility.
NSArray<NSString *> *SPOMissingSymbols(void);

/// Whether this translation unit was compiled with ARC.
///
/// Not trivia: a virtual display is removed only when its CGVirtualDisplay is deallocated, so
/// if ARC were off, teardown would silently leak a phantom monitor. Surfaced in `spaceo doctor`.
BOOL SPOBuiltWithARC(void);

#pragma mark - Stage: headless virtual display

/// Wrapper around a private virtual display. Normal invalidation releases its backing object;
/// higher-level code verifies and reports removal.
@interface SPOVirtualDisplay : NSObject

- (nullable instancetype)initWithName:(NSString *)name
                                width:(uint32_t)width
                               height:(uint32_t)height
                                hiDPI:(BOOL)hiDPI NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) CGDirectDisplayID displayID;
@property (nonatomic, readonly) BOOL valid;
@property (nonatomic, readonly) CGRect bounds;

/// Drop the display now rather than waiting for dealloc.
- (void)invalidate;

@end

#pragma mark - Space graph (read-only)

/// Managed space ids belonging to `displayID`, or nil if the Space API is unavailable.
NSArray<NSNumber *> *_Nullable SPOSpacesForDisplay(CGDirectDisplayID displayID);
/// Space ids a window is currently associated with.
NSArray<NSNumber *> *_Nullable SPOSpacesForWindow(uint32_t windowID);
/// The user's currently active space id (0 when unavailable).
uint64_t SPOActiveSpace(void);
/// Raw SLSCopyManagedDisplaySpaces payload, for `spaceo doctor` diagnostics.
NSArray *_Nullable SPOManagedDisplaySpaces(void);

#pragma mark - Focus routing

/// Flip `pid`'s AppKit-active state so it receives input, WITHOUT raising the window and
/// WITHOUT switching the user's Space.
///
/// This deliberately does not call SLPSSetFrontProcessWithOptions — that is the single API
/// that would raise the window and drag the user to the app's Space.
///
/// Returns NO when the underlying symbol is unavailable.
BOOL SPOFocusWithoutRaise(pid_t pid, uint32_t windowID);

/// Legacy ABI-compatible stub. Always returns 0.
///
/// SpaceO deliberately does not call the private front-process getter; AppKit provides the
/// frontmost application without another guessed private ProcessSerialNumber ABI.
pid_t SPOFrontProcessPID(void);

#pragma mark - Window geometry

/// Window bounds straight from the WindowServer. Works for windows on any display or Space,
/// including ones the user cannot see.
BOOL SPOWindowBounds(uint32_t windowID, CGRect *outBounds);

/// CGWindowID behind an accessibility element, or 0.
uint32_t SPOWindowIDForAXElement(AXUIElementRef element);

NS_ASSUME_NONNULL_END

#endif /* SPACEO_PRIVATE_H */
