import CoreGraphics
import SpaceOPrivate

/// The only SpaceOKit path to the per-process event symbol.
///
/// The Objective-C shim checks the exact evidence-qualified host tuple at the call boundary.
/// A Swift availability check is intentionally not enough: future callers must not be able to
/// bypass qualification merely because the symbol still resolves.
func postEventToPID(_ event: CGEvent, pid: pid_t) throws {
    guard SPOPostEventToPID(pid, event) else {
        let name = SPOCapabilityName(.perPIDEvents)
        let reason = SPOCapabilityUnavailableReason(.perPIDEvents)
        throw SpaceOError.unavailable(
            capability: reason.map { "\(name): \($0)" } ?? name
        )
    }
}
