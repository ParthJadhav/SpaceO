import Foundation

/// Every failure mode SpaceO can produce.
///
/// Error types in this package conform to LocalizedError so that `localizedDescription` —
/// which generic code like `Response.failure` reaches for — carries the deliberate message
/// instead of Foundation's generic "operation couldn't be completed" text.
public enum SpaceOError: Error, CustomStringConvertible, LocalizedError, Equatable {
    /// A private symbol or class this OS build no longer provides.
    case unavailable(capability: String)
    /// Accessibility permission missing. Carries the exact remedy.
    case accessibilityDenied
    /// Screen Recording permission missing.
    case screenRecordingDenied
    /// The virtual display could not be created.
    case stageCreationFailed(String)
    /// No such session.
    case unknownSession(String)
    /// The app could not be launched or never produced a window.
    case launchFailed(String)
    /// No window matched.
    case windowNotFound(String)
    /// The target rejected an operation.
    case unsupportedTarget(String)
    /// The addressed element exists but exposes no press-like action. Distinct from
    /// `unsupportedTarget`: nothing is wrong with the app, the caller just picked a node
    /// that is not a button.
    case elementNotPressable(role: String, actions: [String])
    /// Capture produced nothing usable.
    case captureFailed(String)
    /// A malformed request from the CLI.
    case badRequest(String)

    public var description: String {
        switch self {
        case .unavailable(let cap):
            return """
            unavailable on this build: \(cap)
              The underlying class or symbol is unavailable on this macOS version.
              Run `spaceo doctor` for the full report.
            """
        case .accessibilityDenied:
            return """
            Accessibility permission is required.
              System Settings > Privacy & Security > Accessibility
              Add and enable the terminal or app running spaceo, then retry.
            """
        case .screenRecordingDenied:
            return """
            Screen Recording permission is required for capture.
              System Settings > Privacy & Security > Screen & System Audio Recording
              Input and placement still work without it.
            """
        case .stageCreationFailed(let why):  return "could not create the agent display: \(why)"
        case .unknownSession(let id):        return "no session named '\(id)'"
        case .launchFailed(let why):         return "launch failed: \(why)"
        case .windowNotFound(let why):       return "window not found: \(why)"
        case .unsupportedTarget(let why):
            return "target rejected the operation: \(why)"
        case .elementNotPressable(let role, let actions):
            let available = actions.isEmpty ? "none" : actions.joined(separator: ", ")
            return """
            that element is not pressable: \(role) exposes no press action (available: \(available))
              Pick a Button/Link/CheckBox from `spaceo ax`, or click by coordinate with --x/--y.
              For a text field, `spaceo type` after focusing it is usually what you want.
            """
        case .captureFailed(let why):        return "capture failed: \(why)"
        case .badRequest(let why):           return why
        }
    }

    public var errorDescription: String? { description }
}
