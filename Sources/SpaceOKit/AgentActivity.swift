import Foundation

/// Counts the things SpaceO itself did that could disturb the user.
///
/// Needed because an isolation check that only diffs before/after state cannot tell
/// "the agent grabbed the pointer" from "the user moved their mouse while the command ran".
/// Attributing the latter to SpaceO produces false alarms, and an alarm that cries wolf is
/// worse than no alarm.
public enum AgentActivity {

    private static let lock = NSLock()
    private static var focusFlips = 0
    private static var focusRestores = 0

    /// How many times SpaceO has flipped input routing to a background app.
    public static var focusFlipCount: Int { lock.withLock { focusFlips } }
    /// How many times SpaceO explicitly handed input routing back to the user's app.
    public static var focusRestoreCount: Int { lock.withLock { focusRestores } }

    public static func recordFocusFlip() { lock.withLock { focusFlips += 1 } }
    public static func recordFocusRestore() { lock.withLock { focusRestores += 1 } }

    // MARK: - What belongs to an agent
    //
    // "The frontmost app changed" is only SpaceO's fault if it changed *to one of the agent's
    // apps*. A user switching between their own windows while a command runs is not a breach,
    // and reporting it as one is how a safety check turns into noise everyone learns to ignore.

    private static var agentPIDs: Set<pid_t> = []
    private static var agentSpaces: Set<UInt64> = []

    public static var ownedPIDs: Set<pid_t> { lock.withLock { agentPIDs } }
    public static var ownedSpaces: Set<UInt64> { lock.withLock { agentSpaces } }

    public static func claim(pid: pid_t) { lock.withLock { _ = agentPIDs.insert(pid) } }
    public static func release(pid: pid_t) { lock.withLock { _ = agentPIDs.remove(pid) } }
    public static func claim(spaces: [UInt64]) { lock.withLock { agentSpaces.formUnion(spaces) } }
    public static func release(spaces: [UInt64]) { lock.withLock { agentSpaces.subtract(spaces) } }

    /// Test seam.
    static func reset() {
        lock.withLock {
            focusFlips = 0
            focusRestores = 0
            agentPIDs = []
            agentSpaces = []
        }
    }
}
