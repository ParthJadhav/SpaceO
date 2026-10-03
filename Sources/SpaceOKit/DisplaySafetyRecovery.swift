import Foundation

/// Local operator recovery for an idle unknown-health latch. This never resets a pending
/// display mutation, an incident/pressure failure, or a journal locked by a display owner.
public enum DisplaySafetyRecovery {
    private static let worker = DisplayLifecycleCoordinator()

    public static func clearHostHealthLatch() throws -> String {
        try worker.perform(timeout: 20, onlyWhenIdle: true) { operation in
            try DisplayLifecycleLease.clearHostHealthLatch(checkDeadline: { try operation.check() }) {
                let original = try Stage.checkedOnlineDisplayIDs()
                guard !original.contains(where: Stage.isSpaceODisplay) else {
                    throw SpaceOError.stageCreationFailed("SpaceO displays remain online; host-health recovery refused")
                }
                let health = DisplayHostHealth()
                try health.requireHealthy()
                let final = try Stage.checkedOnlineDisplayIDs()
                guard Set(original) == Set(final), !final.contains(where: Stage.isSpaceODisplay),
                      health.report.state == .ready else {
                    throw SpaceOError.stageCreationFailed("display topology or host health changed during recovery")
                }
                try operation.check()
            }
        }
    }
}
