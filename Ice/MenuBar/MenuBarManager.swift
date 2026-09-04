//
//  MenuBarManager.swift
//  Ice
//

import Combine
import OSLog
import SwiftUI

/// Manager for the state of the menu bar.
@MainActor
final class MenuBarManager: ObservableObject {
    /// Information for the menu bar's average color.
    @Published private(set) var averageColorInfo: MenuBarAverageColorInfo?

    /// A Boolean value that indicates whether the menu bar is either always hidden
    /// by the system, or automatically hidden and shown by the system based on the
    /// location of the mouse.
    @Published private(set) var isMenuBarHiddenBySystem = false

    /// A Boolean value that indicates whether the menu bar is hidden by the system
    /// according to a value stored in UserDefaults.
    @Published private(set) var isMenuBarHiddenBySystemUserDefaults = false

    /// A Boolean value that indicates whether the "ShowOnHover" feature is allowed.
    @Published var showOnHoverAllowed = true

    /// Reference to the settings window.
    @Published private var settingsWindow: NSWindow?

    /// Logger for the menu bar manager.
    private let logger = Logger(category: "MenuBarManager")

    /// The shared app state.
    private weak var appState: AppState?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// A Boolean value that indicates whether the application menus are hidden.
    private var isHidingApplicationMenus = false

    /// Monotonically increasing token used to discard WindowServer results
    /// that arrive after the section or settings state has changed.
    private var applicationMenuEvaluationGeneration = 0

    /// State needed to restore focus after Ice temporarily becomes a regular
    /// app to make room for status items.
    private struct ApplicationMenuHideContext {
        let id: UUID
        let previousApplication: NSRunningApplication?
        let startedAt: TimeInterval
        var didObserveIceFrontmost = false
    }

    private var applicationMenuHideContext: ApplicationMenuHideContext?
    private let diagnosticLogger = AutomationDiagnosticLogger.shared

    /// The panel that contains the Ice Bar interface.
    let iceBarPanel = IceBarPanel()

    /// The panel that contains the menu bar search interface.
    let searchPanel = MenuBarSearchPanel()

    /// The panel that contains a portable version of the menu bar
    /// appearance editor interface
    let appearanceEditorPanel = MenuBarAppearanceEditorPanel()

    /// The managed sections in the menu bar.
    let sections = [
        MenuBarSection(name: .visible),
        MenuBarSection(name: .hidden),
        MenuBarSection(name: .alwaysHidden),
    ]

    /// A Boolean value that indicates whether at least one of the manager's
    /// sections is visible.
    var hasVisibleSection: Bool {
        sections.contains { !$0.isHidden }
    }

    /// Performs the initial setup of the menu bar manager.
    func performSetup(with appState: AppState) {
        self.appState = appState
        configureCancellables()
        iceBarPanel.performSetup(with: appState)
        searchPanel.performSetup(with: appState)
        appearanceEditorPanel.performSetup(with: appState)
        for section in sections {
            section.performSetup(with: appState)
        }
    }

    /// Configures the internal observers for the manager.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        NSApp.publisher(for: \.currentSystemPresentationOptions)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] options in
                guard let self else {
                    return
                }
                let hidden = options.contains(.hideMenuBar) || options.contains(.autoHideMenuBar)
                isMenuBarHiddenBySystem = hidden
            }
            .store(in: &c)

        if
            let hiddenSection = section(withName: .alwaysHidden),
            let window = hiddenSection.controlItem.window
        {
            window.publisher(for: \.frame)
                .map { $0.origin.y }
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard
                        let self,
                        let isMenuBarHidden = Defaults.globalDomain["_HIHideMenuBar"] as? Bool
                    else {
                        return
                    }
                    isMenuBarHiddenBySystemUserDefaults = isMenuBarHidden
                }
                .store(in: &c)
        }

        // Handle the `focusedApp` rehide strategy.
        NSWorkspace.shared.publisher(for: \.frontmostApplication)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] frontmostApplication in
                if
                    let self,
                    let appState,
                    case .focusedApp = appState.settings.general.rehideStrategy,
                    let hiddenSection = section(withName: .hidden),
                    let screen = appState.hidEventManager.bestScreen(appState: appState),
                    !appState.hidEventManager.isMouseInsideMenuBar(appState: appState, screen: screen)
                {
                    Task {
                        try await Task.sleep(for: .seconds(0.1))
                        hiddenSection.hide()
                    }
                }

                // If the user deliberately switches applications while Ice
                // is making room, release the temporary activation policy
                // without pulling the old app back to the front.
                if let self, var context = applicationMenuHideContext {
                    if
                        frontmostApplication?.processIdentifier ==
                            NSRunningApplication.current.processIdentifier
                    {
                        context.didObserveIceFrontmost = true
                        applicationMenuHideContext = context
                    } else if context.didObserveIceFrontmost {
                        finishHidingApplicationMenus(
                            reason: "frontmost-application-changed",
                            restorePreviousApplication: false
                        )
                    }
                }
            }
            .store(in: &c)

        appState?.publisherForWindow(.settings)
            .sink { [weak self] window in
                self?.settingsWindow = window
            }
            .store(in: &c)

        $settingsWindow
            .removeNil()
            .flatMap { $0.publisher(for: \.isVisible) }
            .discardMerge(Timer.publish(every: 5, on: .main, in: .default).autoconnect())
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.updateAverageColorInfo()
            }
            .store(in: &c)

        // Hide application menus when a section is shown (if applicable).
        Publishers.MergeMany(sections.map { $0.controlItem.$state })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.evaluateApplicationMenuVisibility(reason: "section-state")
            }
            .store(in: &c)

        // Settings, fullscreen and system menu-bar changes must actively undo
        // a previous hide. The old implementation only reacted to section
        // state, which could leave Ice frontmost indefinitely.
        appState?.settings.advanced.$hideApplicationMenus
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.evaluateApplicationMenuVisibility(reason: "setting")
            }
            .store(in: &c)

        appState?.settings.general.$useIceBar
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.evaluateApplicationMenuVisibility(reason: "ice-bar-setting")
            }
            .store(in: &c)

        appState?.$activeSpace
            .map(\.isFullscreen)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.evaluateApplicationMenuVisibility(reason: "space")
            }
            .store(in: &c)

        appState?.navigationState.$isSettingsPresented
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.evaluateApplicationMenuVisibility(reason: "settings-window")
            }
            .store(in: &c)

        $isMenuBarHiddenBySystem
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.evaluateApplicationMenuVisibility(reason: "system-menu-bar")
            }
            .store(in: &c)

        // Last-resort recovery for interrupted animations, missed state
        // publications and third-party status items that never close cleanly.
        Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.applicationMenuWatchdogTick()
            }
            .store(in: &c)

        cancellables = c
    }

    /// Updates the ``averageColorInfo`` property with the current average color
    /// of the menu bar.
    func updateAverageColorInfo() {
        guard
            let settingsWindow,
            settingsWindow.isVisible,
            let screen = settingsWindow.screen
        else {
            return
        }

        let windows = WindowInfo.createWindows(option: .onScreen)
        let displayID = screen.displayID

        guard
            let menuBarWindow = WindowInfo.menuBarWindow(from: windows, for: displayID),
            let wallpaperWindow = WindowInfo.wallpaperWindow(from: windows, for: displayID)
        else {
            return
        }

        guard
            let image = ScreenCapture.captureWindows(
                with: [menuBarWindow.windowID, wallpaperWindow.windowID],
                screenBounds: withMutableCopy(of: wallpaperWindow.bounds) { $0.size.height = 1 },
                option: .nominalResolution
            ),
            let color = image.averageColor(option: .ignoreAlpha)
        else {
            return
        }

        let info = MenuBarAverageColorInfo(color: color, source: .menuBarWindow)

        if averageColorInfo != info {
            averageColorInfo = info
        }
    }

    /// Returns a Boolean value that indicates whether the given display
    /// has a valid menu bar.
    func hasValidMenuBar(in windows: [WindowInfo], for display: CGDirectDisplayID) -> Bool {
        guard
            let window = WindowInfo.menuBarWindow(from: windows, for: display),
            let element = AXHelpers.element(at: window.bounds.origin)
        else {
            return false
        }
        return AXHelpers.role(for: element) == .menuBar
    }

    /// Shows the secondary context menu.
    func showSecondaryContextMenu(at point: CGPoint) {
        let menu = NSMenu(title: "Ice")

        let editAppearanceItem = NSMenuItem(
            title: "Edit Menu Bar Appearance…",
            action: #selector(showAppearanceEditorPanel),
            keyEquivalent: ""
        )
        editAppearanceItem.target = self
        menu.addItem(editAppearanceItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Ice Settings…",
            action: #selector(AppDelegate.openSettingsWindow),
            keyEquivalent: ","
        )
        menu.addItem(settingsItem)

        menu.popUp(positioning: nil, at: point, in: nil)
    }

    /// Evaluates whether the active application's menus overlap the status
    /// items that Ice is currently exposing.
    private func evaluateApplicationMenuVisibility(reason: String) {
        applicationMenuEvaluationGeneration += 1
        let generation = applicationMenuEvaluationGeneration

        guard applicationMenusMayBeHidden else {
            finishHidingApplicationMenus(reason: "ineligible-\(reason)")
            return
        }
        guard sections.contains(where: { $0.controlItem.state == .showSection }) else {
            finishHidingApplicationMenus(reason: "sections-hidden")
            return
        }
        guard !isHidingApplicationMenus else {
            return
        }
        guard
            let screen = sections.first(where: { $0.controlItem.state == .showSection })?
                .controlItem.window?.screen ?? NSScreen.main,
            let applicationMenuFrame = screen.getApplicationMenuFrame()
        else {
            diagnosticLogger.write(
                "APP_MENUS_EVALUATE id=\(generation) result=missing-screen-or-frame reason=\(reason)",
                level: .warning
            )
            return
        }

        diagnosticLogger.write(
            "APP_MENUS_EVALUATE id=\(generation) state=start reason=\(reason) " +
            "display=\(screen.displayID) appMenuMaxX=\(applicationMenuFrame.maxX)"
        )

        Task {
            var items = await MenuBarItem.getMenuBarItems(
                on: screen.displayID,
                option: .activeSpace
            )
            guard
                generation == applicationMenuEvaluationGeneration,
                applicationMenusMayBeHidden,
                sections.contains(where: { $0.controlItem.state == .showSection })
            else {
                diagnosticLogger.write(
                    "APP_MENUS_EVALUATE id=\(generation) result=discarded-stale"
                )
                return
            }

            // Filter items down according to enabled and shown sections.
            if
                let alwaysHiddenSection = section(withName: .alwaysHidden),
                alwaysHiddenSection.isEnabled
            {
                if alwaysHiddenSection.controlItem.state == .hideSection,
                   let index = items.firstIndex(matching: .alwaysHiddenControlItem)
                {
                    let controlItem = items.remove(at: index)
                    items.trimPrefix { $0.bounds.maxX <= controlItem.bounds.minX }
                }
            } else if let index = items.firstIndex(matching: .hiddenControlItem) {
                let controlItem = items.remove(at: index)
                items.trimPrefix { $0.bounds.maxX <= controlItem.bounds.minX }
            }

            guard let leftmostItem = items.min(by: { $0.bounds.minX < $1.bounds.minX }) else {
                diagnosticLogger.write(
                    "APP_MENUS_EVALUATE id=\(generation) result=no-items",
                    level: .warning
                )
                return
            }

            let overlaps = leftmostItem.bounds.minX <= applicationMenuFrame.maxX
            diagnosticLogger.write(
                "APP_MENUS_EVALUATE id=\(generation) result=complete " +
                "leftmostMinX=\(leftmostItem.bounds.minX) overlaps=\(overlaps)"
            )
            if overlaps {
                hideApplicationMenus(reason: reason, evaluationID: generation)
            }
        }
    }

    private var applicationMenusMayBeHidden: Bool {
        guard let appState else {
            return false
        }
        return appState.settings.advanced.hideApplicationMenus &&
        (!appState.settings.general.useIceBar || appState.itemManager.isOneDriveNativeRevealActive) &&
        !isMenuBarHiddenBySystem &&
        !appState.activeSpace.isFullscreen &&
        !appState.navigationState.isSettingsPresented
    }

    /// Hides the application menus as a recoverable transaction.
    private func hideApplicationMenus(reason: String, evaluationID: Int) {
        guard !isHidingApplicationMenus else {
            return
        }
        guard let appState else {
            logger.error("Error hiding application menus: Missing app state")
            return
        }
        let currentPID = NSRunningApplication.current.processIdentifier
        let previousApplication = NSWorkspace.shared.frontmostApplication
            .flatMap { $0.processIdentifier == currentPID ? nil : $0 }
        let context = ApplicationMenuHideContext(
            id: UUID(),
            previousApplication: previousApplication,
            startedAt: ProcessInfo.processInfo.systemUptime
        )
        applicationMenuHideContext = context
        isHidingApplicationMenus = true
        diagnosticLogger.write(
            "APP_MENUS_HIDE id=\(context.id.uuidString) state=start evaluation=\(evaluationID) " +
            "reason=\(reason) previousPID=\(previousApplication?.processIdentifier ?? 0)"
        )
        appState.activate(withPolicy: .regular)
    }

    /// Shows the application menus.
    func showApplicationMenus() {
        finishHidingApplicationMenus(reason: "explicit-show")
    }

    private func finishHidingApplicationMenus(
        reason: String,
        restorePreviousApplication: Bool = true
    ) {
        guard isHidingApplicationMenus || applicationMenuHideContext != nil else {
            return
        }
        guard let appState else {
            logger.error("Error showing application menus: Missing app state")
            return
        }
        let context = applicationMenuHideContext
        applicationMenuHideContext = nil
        isHidingApplicationMenus = false
        appState.deactivate(withPolicy: .accessory)

        if
            restorePreviousApplication,
            let previousApplication = context?.previousApplication,
            !previousApplication.isTerminated
        {
            previousApplication.activate()
        }

        let elapsed = context.map {
            ProcessInfo.processInfo.systemUptime - $0.startedAt
        } ?? 0
        let contextID = context?.id.uuidString ?? "unknown"
        diagnosticLogger.write(
            "APP_MENUS_HIDE id=\(contextID) state=end " +
            "reason=\(reason) restorePrevious=\(restorePreviousApplication) " +
            "durationMs=\(Int(elapsed * 1_000))"
        )
    }

    private func applicationMenuWatchdogTick() {
        guard let context = applicationMenuHideContext else {
            return
        }
        guard applicationMenusMayBeHidden else {
            finishHidingApplicationMenus(reason: "watchdog-ineligible")
            return
        }
        guard sections.contains(where: { $0.controlItem.state == .showSection }) else {
            finishHidingApplicationMenus(reason: "watchdog-sections-hidden")
            return
        }
        if ProcessInfo.processInfo.systemUptime - context.startedAt > 120 {
            diagnosticLogger.write(
                "APP_MENUS_WATCHDOG id=\(context.id.uuidString) action=forced-restore",
                level: .warning
            )
            finishHidingApplicationMenus(reason: "watchdog-timeout")
        }
    }

    /// Toggles the visibility of the application menus.
    func toggleApplicationMenus() {
        if isHidingApplicationMenus {
            showApplicationMenus()
        } else {
            hideApplicationMenus(reason: "manual-toggle", evaluationID: -1)
        }
    }

    /// Shows the appearance editor panel.
    @objc private func showAppearanceEditorPanel() {
        guard let screen = MenuBarAppearanceEditorPanel.defaultScreen else {
            return
        }
        appearanceEditorPanel.show(on: screen)
    }

    /// Returns the menu bar section with the given name.
    func section(withName name: MenuBarSection.Name) -> MenuBarSection? {
        sections.first { $0.name == name }
    }

    /// Returns the control item for the menu bar section with the given name.
    func controlItem(withName name: MenuBarSection.Name) -> ControlItem? {
        section(withName: name)?.controlItem
    }
}

// MARK: - MenuBarAverageColorInfo

/// Information for the average color of the menu bar.
struct MenuBarAverageColorInfo: Hashable {
    /// Sources used to compute the average color of the menu bar.
    enum Source: Hashable {
        case menuBarWindow
        case desktopWallpaper
    }

    /// The average color of the menu bar
    var color: CGColor

    /// The source used to compute the color.
    var source: Source

    /// The brightness of the menu bar's color.
    var brightness: CGFloat { color.brightness ?? 0 }

    /// A Boolean value that indicates whether the menu bar has a
    /// bright color.
    ///
    /// This value is `true` if ``brightness`` is above `0.67`. At
    /// the time of writing, if this value is `true`, the menu bar
    /// draws its items with a darker appearance.
    var isBright: Bool { brightness > 0.67 }
}
