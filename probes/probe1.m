// probe1.m — READ-ONLY inspection of the WindowServer space graph via SkyLight private API.
// Verifies: (a) private SLS symbols link & run from an unsigned binary with SIP ON,
//           (b) we can enumerate managed spaces + which windows live on which space.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

extern int      SLSMainConnectionID(void);
extern CFArrayRef SLSCopyManagedDisplaySpaces(int cid);
extern uint64_t SLSGetActiveSpace(int cid);
extern int      SLSSpaceGetType(int cid, uint64_t sid);
extern CFStringRef SLSSpaceCopyName(int cid, uint64_t sid);
extern int      SLSGetSpaceManagementMode(int cid);
extern CFArrayRef SLSCopyWindowsWithOptionsAndTags(int cid, uint32_t owner, CFArrayRef spaces,
                                                   uint32_t options, uint64_t *setTags, uint64_t *clearTags);
extern CGError  SLSGetWindowOwner(int cid, uint32_t wid, int *ownerCid);
extern CGError  SLSConnectionGetPID(int cid, pid_t *pid);

int main(void) { @autoreleasepool {
  int cid = SLSMainConnectionID();
  printf("main connection id      : %d\n", cid);
  printf("space management mode   : %d   (1 = displays have separate spaces)\n", SLSGetSpaceManagementMode(cid));
  printf("active space            : %llu\n", SLSGetActiveSpace(cid));

  CFArrayRef displays = SLSCopyManagedDisplaySpaces(cid);
  printf("managed displays        : %ld\n\n", (long)CFArrayGetCount(displays));

  for (NSDictionary *disp in (__bridge NSArray *)displays) {
    printf("display %s   current=%@\n",
           [[disp[@"Display Identifier"] description] UTF8String],
           disp[@"Current Space"][@"ManagedSpaceID"]);
    for (NSDictionary *sp in disp[@"Spaces"]) {
      uint64_t sid = [sp[@"ManagedSpaceID"] unsignedLongLongValue];
      int type = SLSSpaceGetType(cid, sid);
      CFStringRef nm = SLSSpaceCopyName(cid, sid);
      printf("   space sid=%-4llu uuid=%-38s type=%d (0=user 4=fullscreen 2=system) name=%s\n",
             sid,
             [[sp[@"uuid"] ?: @"-" description] UTF8String],
             type,
             nm ? [(__bridge NSString *)nm UTF8String] : "-");
      if (nm) CFRelease(nm);

      // windows currently associated with this space (all owners, option 0x7 = include all)
      uint64_t setTags = 0, clearTags = 0;
      CFArrayRef spaceArr = (__bridge CFArrayRef)@[ @(sid) ];
      CFArrayRef wins = SLSCopyWindowsWithOptionsAndTags(cid, 0, spaceArr, 0x2, &setTags, &clearTags);
      long n = wins ? CFArrayGetCount(wins) : 0;
      printf("      windows on space: %ld  -> ", n);
      for (long i = 0; i < n && i < 12; i++) {
        uint32_t wid = [((__bridge NSArray *)wins)[i] unsignedIntValue];
        int ownerCid = 0; pid_t pid = 0;
        SLSGetWindowOwner(cid, wid, &ownerCid);
        SLSConnectionGetPID(ownerCid, &pid);
        printf("%u(pid %d) ", wid, pid);
      }
      printf("\n");
      if (wins) CFRelease(wins);
    }
    printf("\n");
  }
  CFRelease(displays);
  return 0;
}}
