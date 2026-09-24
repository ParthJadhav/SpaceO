# September 24 source live regression — NO-GO

The owner authorized testing in the existing idle graphical login. This is implementer
source regression evidence, not qualification of a signed distribution.

- Tested source: `cdfca00b032a2ee841b24c0d7fe157f29131cfe0`.
  Later PR changes include deadline tests, the MCP catalogue fixture, documentation, branch
  policy, and daemon listener cleanup. This record does not qualify those later changes or
  the final commit; a fresh complete live run is required for a release candidate.
- Command: `bash scripts/test.sh live --require-full`.
- Result: 16 tests executed, 15 passed, one failed, zero skipped.
- Failure: `testChromiumWebContentIsDrivenThroughDevTools` failed both its post-launch and
  post-input isolation checks. The launch checkpoint already showed the breach before input:
  Chrome took the menu bar and WindowServer front process and changed the active Space.
- SPAO-192 remains a P0 release blocker. No tag or binary publication is authorized by this run.
- Pre/post doctor inventories match: two online user displays, one active user display,
  unchanged mirror membership, zero SpaceO displays and zero orphaned SpaceO displays.
- The pre-existing default daemon was preserved. Test-owned applications and displays were
  cleaned up by the suite. This inventory check does not erase the recorded focus disturbance.

Raw logs and host snapshots are retained privately under
`.artifacts/release-qualification/`; they are not part of the public repository.
The signed candidate, complete computer-use matrix, Viewer qualification, distribution
verification and release-owner GO remain outstanding.
