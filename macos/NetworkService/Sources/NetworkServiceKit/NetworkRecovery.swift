import Foundation
import Darwin

/// Neither clock follows calendar adjustments. Only continuous time includes
/// sleep, so a blocked work queue is not mistaken for a wake notification.
public struct NetworkClockSample {
    public let continuous: TimeInterval
    public let awake: TimeInterval
    public init(continuous: TimeInterval, awake: TimeInterval) { self.continuous = continuous; self.awake = awake }
    public static func capture() -> NetworkClockSample {
        var scale = mach_timebase_info_data_t()
        mach_timebase_info(&scale)
        let seconds = Double(scale.numer) / Double(scale.denom) / 1_000_000_000
        return NetworkClockSample(continuous: Double(mach_continuous_time()) * seconds, awake: Double(mach_absolute_time()) * seconds)
    }
    public func resumed(after previous: NetworkClockSample) -> Bool {
        continuous - previous.continuous - (awake - previous.awake) > 1
    }
}

/// The initial cleanup is attempted immediately; only its failures schedule
/// these three additional attempts. Polling cannot reset the budget.
public struct NetworkRecoverySchedule {
    public private(set) var nextAttempt: TimeInterval?
    public private(set) var errorCode: String?
    private var attempts = 0
    public init() {}
    public static func preferredFailure(_ current: Error?, _ next: Error) -> Error {
        if let code = (next as? ServiceFailure)?.code, ["unsafeInstallation", "recoveryCorrupt"].contains(code) { return next }
        return current ?? next
    }
    public mutating func reset() { nextAttempt = nil; errorCode = nil; attempts = 0 }
    public mutating func failed(_ error: Error, now: TimeInterval) {
        let code = (error as? ServiceFailure)?.code ?? "recoveryFailed"
        guard ["recoveryFailed", "networkSettingsBusy", "networkSettingsUnavailable", "storageError"].contains(code) else {
            nextAttempt = nil; errorCode = code; return
        }
        let delays: [TimeInterval] = [2, 5, 15]
        guard attempts < delays.count else { nextAttempt = nil; errorCode = "recoveryFailed"; return }
        nextAttempt = now + delays[attempts]; errorCode = "recoveryRequired"
    }
    public mutating func takeDue(now: TimeInterval) -> Bool {
        guard let nextAttempt, now >= nextAttempt else { return false }
        self.nextAttempt = nil; attempts += 1; return true
    }
}
