//
//  MouseHelpers.swift
//  Ice
//

import CoreGraphics
import Foundation
import OSLog
import os.lock

/// Owns the process-wide Quartz cursor hide count.
///
/// Quartz does not identify the caller of `CGDisplayHideCursor`. Every
/// successful call increments one shared count, so nested helpers can leave the
/// cursor hidden long after the operation that needed it has finished. This
/// controller permits a single owner and gives every acquisition a watchdog.
final class CursorVisibilityController: @unchecked Sendable {
    typealias CursorOperation = @Sendable () -> CGError
    typealias DiagnosticLog = @Sendable (_ message: String, _ isWarning: Bool) -> Void

    private struct ActiveLease {
        let id: UUID
        let owner: String
        let startedAt: UInt64
    }

    private enum AcquisitionResult {
        case acquired
        case alreadyHidden(activeOwner: String)
        case failed(CGError)
    }

    private struct ReleaseResult {
        let activeLease: ActiveLease
        let showResult: CGError
    }

    private let state: OSAllocatedUnfairLock<ActiveLease?>
    private let hideOperation: CursorOperation
    private let showOperation: CursorOperation
    private let diagnosticLog: DiagnosticLog

    init(
        hideOperation: @escaping CursorOperation,
        showOperation: @escaping CursorOperation,
        diagnosticLog: @escaping DiagnosticLog
    ) {
        state = OSAllocatedUnfairLock(initialState: nil)
        self.hideOperation = hideOperation
        self.showOperation = showOperation
        self.diagnosticLog = diagnosticLog
    }

    convenience init() {
        self.init(
            hideOperation: {
                CGDisplayHideCursor(CGMainDisplayID())
            },
            showOperation: {
                CGDisplayShowCursor(CGMainDisplayID())
            },
            diagnosticLog: { message, isWarning in
                AutomationDiagnosticLogger.shared.write(
                    message,
                    level: isWarning ? .warning : .info
                )
            }
        )
    }

    /// Acquires the single cursor-hide lease.
    ///
    /// A second acquisition is deliberately a no-op. This prevents accidental
    /// nesting from incrementing Quartz's hide count while still allowing the
    /// original owner to complete normally.
    func acquire(
        owner: String,
        watchdogTimeout: Duration
    ) -> CursorVisibilityLease {
        let id = UUID()
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let result = state.withLock { activeLease -> AcquisitionResult in
            if let activeLease {
                return .alreadyHidden(activeOwner: activeLease.owner)
            }

            let result = hideOperation()
            guard result == .success else {
                return .failed(result)
            }

            activeLease = ActiveLease(id: id, owner: owner, startedAt: startedAt)
            return .acquired
        }

        switch result {
        case .acquired:
            diagnosticLog(
                "CURSOR_HIDE_ACQUIRED id=\(id.uuidString) owner=\(owner) " +
                "watchdog=\(String(describing: watchdogTimeout))",
                false
            )
            let lease = CursorVisibilityLease(id: id, owner: owner, controller: self)
            lease.armWatchdog(after: watchdogTimeout)
            return lease

        case .alreadyHidden(let activeOwner):
            diagnosticLog(
                "CURSOR_HIDE_SKIPPED owner=\(owner) activeOwner=\(activeOwner) reason=already-hidden",
                true
            )
            return CursorVisibilityLease(id: id, owner: owner, controller: nil)

        case .failed(let error):
            Logger.default.error(
                "CGDisplayHideCursor failed with error \(error.logString, privacy: .public)"
            )
            diagnosticLog(
                "CURSOR_HIDE_FAILED owner=\(owner) error=\(error.logString)",
                true
            )
            return CursorVisibilityLease(id: id, owner: owner, controller: nil)
        }
    }

    /// Releases a lease if it is still the active owner.
    ///
    /// `beforeShowing` runs only if this lease still owns the hidden cursor.
    /// This is important for cursor restoration: after watchdog recovery, a
    /// delayed operation must not warp the user's cursor to a stale location.
    @discardableResult
    fileprivate func release(
        id: UUID,
        owner: String,
        reason: CursorVisibilityLease.ReleaseReason,
        beforeShowing: (@Sendable () -> Void)?
    ) -> Bool {
        let result = state.withLock { activeLease -> ReleaseResult? in
            guard let lease = activeLease, lease.id == id else {
                return nil
            }
            beforeShowing?()
            let showResult = showOperation()
            activeLease = nil
            return ReleaseResult(activeLease: lease, showResult: showResult)
        }

        guard let result else {
            return false
        }

        let elapsed = DispatchTime.now().uptimeNanoseconds - result.activeLease.startedAt
        let durationMilliseconds = elapsed / 1_000_000
        let prefix = reason == .watchdog ? "CURSOR_HIDE_WATCHDOG_RELEASED" : "CURSOR_HIDE_RELEASED"
        let warning = reason == .watchdog || result.showResult != .success
        diagnosticLog(
            "\(prefix) id=\(id.uuidString) owner=\(owner) " +
            "reason=\(reason.rawValue) durationMs=\(durationMilliseconds) " +
            "result=\(result.showResult.logString)",
            warning
        )

        if result.showResult != .success {
            Logger.default.error(
                "CGDisplayShowCursor failed with error \(result.showResult.logString, privacy: .public)"
            )
        }
        return true
    }
}

/// A cancellation- and timeout-safe ownership token for the Quartz cursor hide
/// count. Releasing or destroying the token more than once is harmless.
final class CursorVisibilityLease: @unchecked Sendable {
    fileprivate enum ReleaseReason: String {
        case scope
        case watchdog
        case deinitFallback = "deinit"
    }

    private struct State {
        var isReleased = false
        var watchdogTask: Task<Void, Never>?
    }

    private let id: UUID
    private let owner: String
    private let controller: CursorVisibilityController?
    private let state = OSAllocatedUnfairLock(initialState: State())

    fileprivate init(
        id: UUID,
        owner: String,
        controller: CursorVisibilityController?
    ) {
        self.id = id
        self.owner = owner
        self.controller = controller
    }

    fileprivate func armWatchdog(after timeout: Duration) {
        guard controller != nil else {
            return
        }
        let watchdogTask = Task.detached(priority: .utility) { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            self?.finish(reason: .watchdog, beforeShowing: nil)
        }
        let shouldCancel = state.withLock { state in
            guard !state.isReleased else {
                return true
            }
            state.watchdogTask = watchdogTask
            return false
        }
        if shouldCancel {
            watchdogTask.cancel()
        }
    }

    /// Restores the cursor once. The optional closure is run immediately before
    /// the cursor is shown, but only if the watchdog has not already recovered
    /// it.
    @discardableResult
    func release(beforeShowing: (@Sendable () -> Void)? = nil) -> Bool {
        finish(reason: .scope, beforeShowing: beforeShowing)
    }

    @discardableResult
    private func finish(
        reason: ReleaseReason,
        beforeShowing: (@Sendable () -> Void)?
    ) -> Bool {
        let releaseState = state.withLock { state -> (shouldRelease: Bool, watchdogTask: Task<Void, Never>?) in
            guard !state.isReleased else {
                return (false, nil)
            }
            state.isReleased = true
            return (true, state.watchdogTask.take())
        }
        guard releaseState.shouldRelease, let controller else {
            return false
        }
        if reason != .watchdog {
            releaseState.watchdogTask?.cancel()
        }
        return controller.release(
            id: id,
            owner: owner,
            reason: reason,
            beforeShowing: beforeShowing
        )
    }

    deinit {
        finish(reason: .deinitFallback, beforeShowing: nil)
    }
}

/// A namespace for mouse helper operations.
enum MouseHelpers {
    /// The single owner of Quartz's process-wide cursor hide count.
    private static let cursorVisibilityController = CursorVisibilityController()

    /// Returns the location of the mouse cursor in the coordinate
    /// space used by `AppKit`, with the origin at the bottom left
    /// of the screen.
    static var locationAppKit: CGPoint? {
        CGEvent(source: nil)?.unflippedLocation
    }

    /// Returns the location of the mouse cursor in the coordinate
    /// space used by `CoreGraphics`, with the origin at the top left
    /// of the screen.
    static var locationCoreGraphics: CGPoint? {
        CGEvent(source: nil)?.location
    }

    /// Hides the mouse cursor for one short synthetic event operation.
    ///
    /// The watchdog is intentionally shorter than the surrounding move retry
    /// lifecycle. A retry may wait indefinitely for the user to pause input,
    /// but the cursor must never remain hidden while it does so.
    static func hideCursor(
        owner: String,
        watchdogTimeout: Duration = .seconds(2)
    ) -> CursorVisibilityLease {
        cursorVisibilityController.acquire(
            owner: owner,
            watchdogTimeout: watchdogTimeout
        )
    }

    /// Moves the mouse cursor to the given point without generating
    /// events.
    ///
    /// - Parameter point: The point to move the cursor to in global
    ///   display coordinates.
    static func warpCursor(to point: CGPoint) {
        let result = CGWarpMouseCursorPosition(point)
        if result != .success {
            Logger.default.error("CGWarpMouseCursorPosition failed with error \(result.logString, privacy: .public)")
        }
    }

    /// Connects or disconnects the positions of the mouse and cursor.
    ///
    /// - Parameter connected: A Boolean value that determines whether
    ///   to connect or disconnect the positions.
    static func associateMouseAndCursor(_ connected: Bool) {
        let result = CGAssociateMouseAndMouseCursorPosition(connected ? 1 : 0)
        if result != .success {
            Logger.default.error("CGAssociateMouseAndMouseCursorPosition failed with error \(result.logString, privacy: .public)")
        }
    }

    /// Returns a Boolean value that indicates whether a mouse button
    /// is pressed.
    ///
    /// - Parameter button: The mouse button to check. Pass `nil` to
    ///   check all available mouse buttons (Quartz supports up to 32).
    static func isButtonPressed(_ button: CGMouseButton? = nil) -> Bool {
        let stateID = CGEventSourceStateID.combinedSessionState
        if let button {
            return CGEventSource.buttonState(stateID, button: button)
        }
        for n: UInt32 in 0...31 {
            guard
                let button = CGMouseButton(rawValue: n),
                CGEventSource.buttonState(stateID, button: button)
            else {
                continue
            }
            return true
        }
        return false
    }

    /// Returns a Boolean value that indicates whether the last mouse
    /// movement event occurred within the given duration.
    ///
    /// - Parameter duration: The duration within which the last mouse
    ///   movement event must have occurred in order to return `true`.
    static func lastMovementOccurred(within duration: Duration) -> Bool {
        let stateID = CGEventSourceStateID.combinedSessionState
        let seconds = CGEventSource.secondsSinceLastEventType(stateID, eventType: .mouseMoved)
        return .seconds(seconds) <= duration
    }

    /// Returns a Boolean value that indicates whether the last scroll
    /// wheel event occurred within the given duration.
    ///
    /// - Parameter duration: The duration within which the last scroll
    ///   wheel event must have occurred in order to return `true`.
    static func lastScrollWheelOccurred(within duration: Duration) -> Bool {
        let stateID = CGEventSourceStateID.combinedSessionState
        let seconds = CGEventSource.secondsSinceLastEventType(stateID, eventType: .scrollWheel)
        return .seconds(seconds) <= duration
    }
}
