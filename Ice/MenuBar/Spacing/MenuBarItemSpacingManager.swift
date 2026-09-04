//
//  MenuBarItemSpacingManager.swift
//  Ice
//

import Cocoa
import OSLog

/// Manager for menu bar item spacing.
@MainActor
final class MenuBarItemSpacingManager {
    /// UserDefaults keys.
    private enum Key: String {
        case spacing = "NSStatusItemSpacing"
        case padding = "NSStatusItemSelectionPadding"

        /// The default value for the key.
        var defaultValue: Int {
            switch self {
            case .spacing: 16
            case .padding: 16
            }
        }
    }

    /// An error that groups multiple failed app relaunches.
    private struct GroupedRelaunchError: LocalizedError {
        let failedApps: [String]

        var errorDescription: String? {
            "The following applications failed to quit and were not restarted:\n" + failedApps.joined(separator: "\n")
        }

        var recoverySuggestion: String? {
            "You may need to log out for the changes to take effect."
        }
    }

    private struct CommandError: LocalizedError {
        let command: String
        let exitStatus: Int32

        var errorDescription: String? {
            "\(command) exited with status \(exitStatus)"
        }
    }

    private struct TerminationError: LocalizedError {
        let appName: String

        var errorDescription: String? {
            "\(appName) did not terminate"
        }
    }

    /// Logger for the menu bar item spacing manager.
    private let logger = Logger(category: "MenuBarItemSpacingManager")

    private let diagnosticLogger = AutomationDiagnosticLogger.shared

    /// Delay before force terminating an app.
    private let forceTerminateDelay: Duration = .seconds(1)

    /// Maximum wait after asking macOS to force terminate an app.
    private let forceTerminateTimeout: Duration = .seconds(2)

    /// The offset to apply to the default spacing and padding.
    /// Does not take effect until ``applyOffset()`` is called.
    var offset = 0

    /// Runs a command with the given arguments.
    @discardableResult
    private func runCommand(
        _ command: String,
        with arguments: [String],
        acceptedExitCodes: Set<Int32> = [0]
    ) async throws -> Int32 {
        let process = Process()

        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = CollectionOfOne(command) + arguments

        let task = Task.detached {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }

        let exitStatus = try await task.value
        guard acceptedExitCodes.contains(exitStatus) else {
            throw CommandError(command: command, exitStatus: exitStatus)
        }
        return exitStatus
    }

    /// Removes the value for the specified key.
    private func removeValue(forKey key: Key) async throws {
        // `defaults delete` returns 1 when an already-absent key is reset.
        let status = try await runCommand(
            "defaults",
            with: ["-currentHost", "delete", "-globalDomain", key.rawValue],
            acceptedExitCodes: [0, 1]
        )
        if status != 0 {
            logger.debug("Spacing key \(key.rawValue, privacy: .public) was already absent")
        }
    }

    /// Sets the value for the specified key to the key's default value plus the given offset.
    private func setOffset(_ offset: Int, forKey key: Key) async throws {
        try await runCommand("defaults", with: ["-currentHost", "write", "-globalDomain", key.rawValue, "-int", String(key.defaultValue + offset)])
    }

    private func waitForTermination(
        of app: NSRunningApplication,
        timeout: Duration
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !app.isTerminated, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return app.isTerminated
    }

    /// Asynchronously signals the given app to quit.
    private func signalAppToQuit(_ app: NSRunningApplication) async throws {
        if app.isTerminated {
            logger.debug("Application \"\(app.logString, privacy: .public)\" is already terminated")
            return
        } else {
            logger.debug("Signaling application \"\(app.logString, privacy: .public)\" to quit")
        }

        app.terminate()
        if await waitForTermination(of: app, timeout: forceTerminateDelay) {
            logger.debug("Application \"\(app.logString, privacy: .public)\" terminated successfully")
            return
        }

        logger.debug(
            "Application \"\(app.logString, privacy: .public)\" did not terminate gracefully, attempting force terminate"
        )
        app.forceTerminate()
        guard await waitForTermination(of: app, timeout: forceTerminateTimeout) else {
            throw TerminationError(appName: app.logString)
        }
        logger.debug("Application \"\(app.logString, privacy: .public)\" force terminated successfully")
    }

    /// Asynchronously launches the app at the given URL.
    private nonisolated func launchApp(
        at applicationURL: URL,
        bundleIdentifier: String,
        replacing replacedPID: pid_t
    ) async throws {
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleIdentifier &&
            $0.processIdentifier != replacedPID &&
            !$0.isTerminated
        }) {
            logger.debug("Application \"\(app.logString, privacy: .public)\" is already open, so skipping launch")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false
        configuration.promptsUserIfNeeded = false
        try await NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration)
    }

    /// Asynchronously relaunches the given app.
    private func relaunchApp(_ app: NSRunningApplication) async throws {
        struct RelaunchError: Error { }
        guard
            let url = app.bundleURL,
            let bundleIdentifier = app.bundleIdentifier
        else {
            throw RelaunchError()
        }
        let replacedPID = app.processIdentifier
        try await signalAppToQuit(app)
        if app.isTerminated {
            try await launchApp(
                at: url,
                bundleIdentifier: bundleIdentifier,
                replacing: replacedPID
            )
        } else {
            throw RelaunchError()
        }
    }

    /// Applies the current ``offset``.
    ///
    /// - Note: Calling this restarts all apps with a menu bar item.
    func applyOffset() async throws {
        guard (-16...16).contains(offset) else {
            throw CommandError(command: "spacing validation", exitStatus: -1)
        }
        diagnosticLogger.write("SPACING_APPLY_START offset=\(offset)")
        if offset == 0 {
            try await removeValue(forKey: .spacing)
            try await removeValue(forKey: .padding)
        } else {
            try await setOffset(offset, forKey: .spacing)
            try await setOffset(offset, forKey: .padding)
        }

        try? await Task.sleep(for: .milliseconds(100))

        let items = await MenuBarItem.getMenuBarItems(option: .activeSpace)
        let pids = Set(items.map { $0.sourcePID ?? $0.ownerPID }).sorted()

        var failedApps = [String]()

        await withTaskGroup(of: Void.self) { group in
            for pid in pids {
                guard let app = NSRunningApplication(processIdentifier: pid) else {
                    diagnosticLogger.write("SPACING_APP_SKIPPED pid=\(pid) reason=stale-pid")
                    continue
                }
                guard app.bundleIdentifier != "com.apple.controlcenter" else {
                    diagnosticLogger.write("SPACING_APP_SKIPPED pid=\(pid) reason=control-center-last")
                    continue
                }
                guard app != .current else {
                    diagnosticLogger.write("SPACING_APP_SKIPPED pid=\(pid) reason=ice")
                    continue
                }
                group.addTask { @MainActor in
                    do {
                        self.diagnosticLogger.write(
                            "SPACING_APP_RELAUNCH_START pid=\(pid) app=\(app.logString)"
                        )
                        try await self.relaunchApp(app)
                        self.diagnosticLogger.write(
                            "SPACING_APP_RELAUNCH_SUCCESS pid=\(pid) app=\(app.logString)"
                        )
                    } catch {
                        self.diagnosticLogger.write(
                            "SPACING_APP_RELAUNCH_FAILURE pid=\(pid) app=\(app.logString) " +
                            "error=\(String(describing: error))",
                            level: .error
                        )
                        guard let name = app.localizedName else {
                            return
                        }
                        if app.bundleIdentifier == "com.apple.Spotlight" {
                            // Spotlight automatically relaunches, so only consider it a failure if it never quit.
                            if
                                let latestSpotlightInstance = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Spotlight").first,
                                latestSpotlightInstance.processIdentifier == app.processIdentifier
                            {
                                failedApps.append(name)
                            }
                        } else {
                            failedApps.append(name)
                        }
                    }
                }
            }
        }

        try? await Task.sleep(for: .milliseconds(100))

        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first {
            do {
                diagnosticLogger.write(
                    "SPACING_CONTROL_CENTER_RESTART_START pid=\(app.processIdentifier)"
                )
                try await signalAppToQuit(app)
                diagnosticLogger.write("SPACING_CONTROL_CENTER_RESTART_SUCCESS")
            } catch {
                diagnosticLogger.write(
                    "SPACING_CONTROL_CENTER_RESTART_FAILURE error=\(String(describing: error))",
                    level: .error
                )
                if let name = app.localizedName {
                    failedApps.append(name)
                }
            }
        }

        if !failedApps.isEmpty {
            diagnosticLogger.write(
                "SPACING_APPLY_FINISH offset=\(offset) result=partial-failure failedApps=" +
                failedApps.sorted().joined(separator: ","),
                level: .warning
            )
            throw GroupedRelaunchError(failedApps: failedApps)
        }
        diagnosticLogger.write("SPACING_APPLY_FINISH offset=\(offset) result=success")
    }
}

private extension NSRunningApplication {
    /// A string to use for logging purposes.
    var logString: String {
        localizedName ?? bundleIdentifier ?? "<NIL>"
    }
}
