//
//  SpaceOPrivate.h
//  The one place in SpaceO that touches private macOS API.
//
//  Every private operation is admitted only for an exact, evidence-backed host tuple before
//  its resolved symbol, Objective-C surface, or assumed record layout can be used. Symbol
//  presence alone is never compatibility evidence.
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

/// One exact ABI/behavior host: macOS version, Darwin build, and process architecture.
///
/// `evidenceReference` belongs on registry entries, not the observed runtime tuple. A registry
/// entry without a durable disposable-login evidence reference is deliberately ignored.
@interface SPOHostTuple : NSObject

- (instancetype)initWithOperatingSystemMajor:(NSInteger)major
                                       minor:(NSInteger)minor
                                       patch:(NSInteger)patch
                                 darwinBuild:(NSString *)darwinBuild
                                architecture:(NSString *)architecture
                           evidenceReference:(nullable NSString *)evidenceReference
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) NSInteger operatingSystemMajor;
@property (nonatomic, readonly) NSInteger operatingSystemMinor;
@property (nonatomic, readonly) NSInteger operatingSystemPatch;
@property (nonatomic, copy, readonly) NSString *darwinBuild;
@property (nonatomic, copy, readonly) NSString *architecture;
@property (nonatomic, copy, readonly, nullable) NSString *evidenceReference;

@end

/// Qualification is capability-specific. Evidence for one private layout must never unlock
/// another layout on the same host tuple.
@interface SPOHostQualification : NSObject

- (instancetype)initWithCapability:(SPOCapability)capability
                              host:(SPOHostTuple *)host NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) SPOCapability capability;
@property (nonatomic, strong, readonly) SPOHostTuple *host;

@end

/// The observed runtime tuple. A tuple is descriptive, not proof of compatibility.
SPOHostTuple *SPOCurrentHostTuple(void);
NSString *SPOHostTupleDescription(SPOHostTuple *host);

/// Evidence-backed entries compiled into this release. This intentionally returns an empty
/// array until disposable-login validation artifacts exist for a specific capability and tuple.
NSArray<SPOHostQualification *> *SPOQualifiedHostRegistry(void);

/// Pure compatibility functions exposed so exact-match and fail-closed behavior can be tested
/// with injected tuples without invoking any private API.
BOOL SPOHostIsQualifiedForCapability(
    SPOCapability cap,
    SPOHostTuple *host,
    NSArray<SPOHostQualification *> *registry
);
BOOL SPOCapabilityAllowedForHost(
    SPOCapability cap,
    SPOHostTuple *host,
    NSArray<SPOHostQualification *> *registry,
    BOOL requiredBehaviorPresent
);

/// YES only when both the exact host tuple is evidence-qualified for this capability and every
/// required symbol/class is present. Symbol presence alone can never make this return YES.
BOOL SPOCapabilityAvailable(SPOCapability cap);
NSString *SPOCapabilityName(SPOCapability cap);
/// Nil when available; otherwise a user-facing host-qualification or symbol/class reason.
NSString *_Nullable SPOCapabilityUnavailableReason(SPOCapability cap);
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

/// Result of the three-record private focus transaction.
///
/// A private record can mutate WindowServer state even when it returns an error, so every
/// result after a record was attempted is explicitly mutation-possible.
typedef NS_ENUM(NSInteger, SPOFocusResult) {
    /// No private record was posted (symbol/process lookup failed).
    SPOFocusResultNotAttempted = 0,
    /// The activation record was attempted and may have mutated the global input route.
    SPOFocusResultFailedAfterActivationRecord,
    /// The key-window-down record was attempted after activation and may have partially applied.
    SPOFocusResultFailedAfterKeyDownRecord,
    /// The key-window-up record was attempted and may have partially applied.
    SPOFocusResultFailedAfterKeyUpRecord,
    /// All three records were accepted.
    SPOFocusResultSucceeded,
};

/// Flip `pid`'s AppKit-active state so it receives input, WITHOUT raising the window and
/// WITHOUT switching the user's Space.
///
/// This deliberately does not call SLPSSetFrontProcessWithOptions — that is the single API
/// that would raise the window and drag the user to the app's Space.
///
/// Reports whether no record was attempted, all records succeeded, or which attempted record
/// failed after the transaction had become mutation-possible.
SPOFocusResult SPOFocusWithoutRaiseResult(pid_t pid, uint32_t windowID);

/// Compatibility wrapper. Prefer `SPOFocusWithoutRaiseResult` so failure is not mistaken for
/// proof that the input route was unchanged.
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

#pragma mark - Per-process event delivery

/// Post through the resolved per-PID event symbol only after exact host qualification.
/// Returns NO without posting when the host or symbol is not admitted.
BOOL SPOPostEventToPID(pid_t pid, CGEventRef event);

NS_ASSUME_NONNULL_END

#endif /* SPACEO_PRIVATE_H */
