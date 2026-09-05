//
//  TemporaryRehideRetryState.swift
//  Ice
//

import Foundation

/// A per-interaction circuit breaker, independent of timer callbacks and wall-clock changes.
/// A new explicit interaction creates a new state; timer firings never reset the budget.
struct TemporaryRehideRetryState {
    static let maximumFailures = 6

    private(set) var failureCount = 0
    private(set) var retryNotBefore: TimeInterval = 0

    var isSuspended: Bool { failureCount >= Self.maximumFailures }

    func delayUntilRetry(now: TimeInterval) -> TimeInterval? {
        guard !isSuspended else { return nil }
        return max(0, retryNotBefore - now)
    }

    /// Returns the next delay, or nil when automatic attempts must stop.
    @discardableResult
    mutating func recordFailure(now: TimeInterval) -> TimeInterval? {
        guard !isSuspended else { return nil }
        failureCount += 1
        guard !isSuspended else { return nil }
        let delay = min(30, 3 * pow(2, Double(failureCount - 1)))
        retryNotBefore = now + delay
        return delay
    }
}

/// A new explicit click may install a timer while an older pass awaits a move.
/// Preserve that timer, but stop entirely when no automatic retries remain.
enum TemporaryRehideTimerAction: Equatable {
    case stop
    case keepExisting
    case schedule(TimeInterval)

    static func decide(pendingDelays: [TimeInterval], hasValidTimer: Bool) -> Self {
        guard let delay = pendingDelays.min() else { return .stop }
        if hasValidTimer { return .keepExisting }
        return .schedule(max(3, delay))
    }
}

/// macOS 26 may host a source app's status window in Control Center. Either
/// process terminating ends this specific temporary interaction; a hidden
/// window or a different active Space does not prove that the owner died.
struct TemporaryRehideOwner {
    let sourcePID: pid_t?
    let windowOwnerPID: pid_t

    func wasTerminated(_ pid: pid_t) -> Bool {
        sourcePID == pid || windowOwnerPID == pid
    }

    /// An unresolved source remains ambiguous, but a known replacement source
    /// or host must not inherit an expired window's exclusion.
    func matches(sourcePID liveSourcePID: pid_t?, windowOwnerPID liveOwnerPID: pid_t) -> Bool {
        windowOwnerPID == liveOwnerPID &&
            (sourcePID == nil || liveSourcePID == nil || sourcePID == liveSourcePID)
    }
}
