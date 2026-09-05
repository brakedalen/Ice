//
//  AppPermissions.swift
//  Ice
//

import Combine
import Cocoa
import OSLog

/// A type that manages the permissions of the app.
@MainActor
final class AppPermissions: ObservableObject {
    /// Keys to access individual permissions.
    enum PermissionKey {
        case accessibility
        case screenRecording
    }

    /// The state of the app's granted permissions.
    enum PermissionsState {
        case missing
        case hasAll
        case hasRequired
    }

    /// The manager's logger.
    let logger = Logger(category: "Permissions")

    /// The permission for Accessibility features.
    let accessibility: Permission

    /// The permission for Screen Recording features.
    let screenRecording: Permission

    /// The state of the app's granted permissions.
    @Published private(set) var permissionsState: PermissionsState = .missing

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// The permissions required for full app functionality.
    var allPermissions: [Permission] {
        [accessibility, screenRecording]
    }

    /// The permissions required for basic app functionality.
    var requiredPermissions: [Permission] {
        allPermissions.filter { $0.isRequired }
    }

    /// Creates a new permissions manager.
    convenience init() {
        self.init(accessibility: AccessibilityPermission(), screenRecording: ScreenRecordingPermission())
    }

    init(accessibility: Permission, screenRecording: Permission, observesLifecycle: Bool = true) {
        self.accessibility = accessibility
        self.screenRecording = screenRecording

        Publishers.CombineLatest(accessibility.$hasPermission, screenRecording.$hasPermission)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .sink { [weak self] accessibility, screenRecording in
                self?.updatePermissionsState(accessibility: accessibility, screenRecording: screenRecording)
            }
            .store(in: &cancellables)

        if observesLifecycle {
            configureLifecycleChecks()
        }
    }

    /// Updates the current permissions state.
    private func updatePermissionsState(accessibility: Bool, screenRecording: Bool) {
        let state: PermissionsState = if accessibility && screenRecording {
            .hasAll
        } else if accessibility {
            .hasRequired
        } else {
            .missing
        }
        if permissionsState != state {
            permissionsState = state
        } else {
            // The individual labels still need updating if, for example,
            // screen recording changes while Accessibility remains missing.
            objectWillChange.send()
        }
    }

    private func configureLifecycleChecks() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let wakeEvents = Publishers.MergeMany([
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ].map { workspaceCenter.publisher(for: $0) })
            .map { _ in () }

        // Ice need not become frontmost after a permission change. Recheck
        // when the user leaves System Settings as well as on app activation.
        let settingsEvents = workspaceCenter.publisher(for: NSWorkspace.didDeactivateApplicationNotification)
            .filter { notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                return app?.bundleIdentifier == "com.apple.systempreferences"
            }
            .map { _ in () }

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .map { _ in () }
            .merge(with: wakeEvents, settingsEvents)
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshAll(reason: "lifecycle")
            }
            .store(in: &cancellables)
    }

    /// Also available to capture/event failure handling for an immediate check.
    func refreshAll(reason: String) {
        for permission in allPermissions {
            permission.refresh(reason: reason)
        }
    }

    func setPermissionUIVisible(_ isVisible: Bool) {
        for permission in allPermissions {
            permission.setPermissionUIVisible(isVisible)
        }
    }

    /// Stops running all permissions checks.
    func stopAllChecks() {
        logger.info("Stopping all permissions checks")
        cancellables.removeAll()
        for permission in allPermissions {
            permission.stopCheck()
        }
    }
}
