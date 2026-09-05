//
//  Permission.swift
//  Ice
//

import Combine
import Cocoa

// MARK: - Permission

/// An object that encapsulates the behavior of checking for and requesting
/// a specific permission for the app.
@MainActor
class Permission: ObservableObject, Identifiable {
    /// A Boolean value that indicates whether the app has this permission.
    @Published private(set) var hasPermission = false

    /// The title of the permission.
    let title: String

    /// Descriptive details for the permission.
    let details: [String]

    /// A Boolean value that indicates if the app can work without this permission.
    let isRequired: Bool

    /// A Boolean value that indicates whether the app may need to relaunch
    /// before this permission becomes usable.
    let mayRequireRelaunch: Bool

    /// The URLs of the settings panes to try to open.
    private let settingsURLs: [URL]

    /// The function that checks permissions.
    private let check: () -> Bool

    /// The function that requests permissions.
    private let request: () -> Void

    /// Observer that runs on a timer to check permissions.
    private var timerCancellable: AnyCancellable?

    /// Pending requests have independent continuations, so repeated requests
    /// and cancellation cannot strand an earlier caller.
    private var waiters = [UUID: CheckedContinuation<Bool, Never>]()

    private let onCheck: (Bool) -> Void
    private let now: () -> TimeInterval
    private let diagnosticLog: (String) -> Void
    private let schedulesChecks: Bool
    private var checksEnabled = true
    private var isPermissionUIVisible = false
    private var requestPollingDeadline: TimeInterval?
    private var checkCount = 0

    /// The active polling policy. Exposed internally for deterministic QA.
    private(set) var pollingInterval: TimeInterval?

    /// Creates a permission.
    ///
    /// - Parameters:
    ///   - title: The title of the permission.
    ///   - details: Descriptive details for the permission.
    ///   - isRequired: A Boolean value that indicates if the app can work without this permission.
    ///   - settingsURLs: The URLs of the settings panes to open.
    ///   - check: A function that checks permissions.
    ///   - request: A function that requests permissions.
    init(
        title: String,
        details: [String],
        isRequired: Bool,
        mayRequireRelaunch: Bool = false,
        settingsURLs: [URL] = [],
        check: @escaping () -> Bool,
        request: @escaping () -> Void,
        onCheck: @escaping (Bool) -> Void = { _ in },
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        schedulesChecks: Bool = true,
        diagnosticLog: @escaping (String) -> Void = { AutomationDiagnosticLogger.shared.write($0) }
    ) {
        self.title = title
        self.details = details
        self.isRequired = isRequired
        self.mayRequireRelaunch = mayRequireRelaunch
        self.settingsURLs = settingsURLs
        self.check = check
        self.request = request
        self.onCheck = onCheck
        self.now = now
        self.schedulesChecks = schedulesChecks
        self.diagnosticLog = diagnosticLog
        refresh(reason: "startup")
    }

    /// Performs a live check, synchronizing capture consumers before publishing
    /// a real state transition. Unchanged checks do not invalidate SwiftUI.
    func refresh(reason: String) {
        let start = now()
        let granted = check()
        let durationMs = max(Int((now() - start) * 1_000), 0)
        checkCount += 1
        onCheck(granted)

        let changed = hasPermission != granted
        if changed {
            hasPermission = granted
        }
        if granted {
            requestPollingDeadline = nil
            finishAllWaiters(granted: true)
        }
        if changed || checkCount == 1 || durationMs >= 100 {
            diagnosticLog(
                "PERMISSION_CHECK permission=\(title) reason=\(reason) granted=\(granted) " +
                "changed=\(changed) count=\(checkCount) durationMs=\(durationMs)"
            )
        }
        updatePolling()
    }

    /// Keeps revocation detection active for this background accessory app,
    /// while allowing macOS to coalesce the infrequent idle timer.
    private func updatePolling() {
        guard checksEnabled else {
            return
        }
        let requestIsRecent = requestPollingDeadline.map { now() < $0 } ?? false
        let interval: TimeInterval = !hasPermission && (isPermissionUIVisible || requestIsRecent) ? 1 : 30
        guard pollingInterval != interval else {
            return
        }
        timerCancellable?.cancel()
        timerCancellable = nil
        pollingInterval = interval
        diagnosticLog("PERMISSION_POLLING permission=\(title) intervalSeconds=\(Int(interval))")
        guard schedulesChecks else {
            return
        }
        timerCancellable = Timer.publish(every: interval, tolerance: interval / 5, on: .main, in: .default)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refresh(reason: "timer")
            }
    }

    func setPermissionUIVisible(_ isVisible: Bool) {
        guard isPermissionUIVisible != isVisible else {
            return
        }
        isPermissionUIVisible = isVisible
        if isVisible {
            refresh(reason: "permission-ui")
        } else {
            updatePolling()
        }
    }

    private func beginRequestPolling() {
        checksEnabled = true
        // A forgotten System Settings window must not leave one-second
        // polling running forever. The slow safety check continues afterward.
        requestPollingDeadline = now() + 120
        updatePolling()
    }

    /// Performs the request and opens the System Settings app to the appropriate pane.
    func performRequest() {
        beginRequestPolling()
        request()
        openSettingsPane()
        refresh(reason: "request")
    }

    /// Opens the most relevant System Settings pane for the permission.
    private func openSettingsPane() {
        guard !settingsURLs.isEmpty else {
            return
        }

        if #available(macOS 13, *) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/System Settings.app"), configuration: configuration)
        }

        if openSettingsURLFallbacks() {
            return
        }

        for settingsURL in settingsURLs {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [settingsURL.absoluteString]

            do {
                try process.run()
                return
            } catch {
                continue
            }
        }
    }

    /// Attempts to open each settings URL through NSWorkspace.
    private func openSettingsURLFallbacks() -> Bool {
        for settingsURL in settingsURLs where NSWorkspace.shared.open(settingsURL) {
            return true
        }
        return false
    }

    /// Returns `false` if the caller is cancelled or permission checks stop.
    func waitForPermission() async -> Bool {
        guard !Task.isCancelled else {
            return false
        }
        beginRequestPolling()
        refresh(reason: "wait")
        guard !hasPermission else {
            return true
        }

        let id = UUID()
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Cancellation can precede registration. Both this check and
                // registration run on the main actor without suspension.
                if Task.isCancelled || !checksEnabled {
                    continuation.resume(returning: false)
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.waiters.removeValue(forKey: id)?.resume(returning: false)
            }
        }
        return granted && !Task.isCancelled
    }

    private func finishAllWaiters(granted: Bool) {
        let pending = waiters
        waiters.removeAll()
        for continuation in pending.values {
            continuation.resume(returning: granted)
        }
    }

    /// Stops running the permission check.
    func stopCheck() {
        checksEnabled = false
        timerCancellable?.cancel()
        timerCancellable = nil
        pollingInterval = nil
        requestPollingDeadline = nil
        finishAllWaiters(granted: false)
        diagnosticLog("PERMISSION_POLLING permission=\(title) stopped=true")
    }
}

// MARK: - AccessibilityPermission

final class AccessibilityPermission: Permission {
    init() {
        super.init(
            title: "Accessibility",
            details: [
                "Get real-time information about the menu bar.",
                "Arrange menu bar items.",
            ],
            isRequired: true,
            mayRequireRelaunch: false,
            settingsURLs: [],
            check: {
                AXHelpers.isProcessTrusted()
            },
            request: {
                AXHelpers.isProcessTrusted(prompt: true)
            }
        )
    }
}

// MARK: - ScreenRecordingPermission

final class ScreenRecordingPermission: Permission {
    init() {
        super.init(
            title: "Screen Recording",
            details: [
                "Change the menu bar's appearance.",
                "Display images of individual menu bar items.",
            ],
            isRequired: false,
            mayRequireRelaunch: true,
            settingsURLs: [
                URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"),
                URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy"),
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"),
            ].compactMap { $0 },
            check: {
                ScreenCapture.checkPermissions()
            },
            request: {
                ScreenCapture.requestPermissions()
            },
            onCheck: {
                ScreenCapture.updateCachedPermissions($0)
            }
        )
    }
}
