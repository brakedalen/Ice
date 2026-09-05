//
//  MenuBarOverlayPanel.swift
//  Ice
//

import Cocoa
import Combine
import OSLog

// MARK: - Overlay Panel

/// A subclass of `NSPanel` that sits atop the menu bar to alter its appearance.
final class MenuBarOverlayPanel: NSPanel {
    /// Flags representing the updatable components of a panel.
    enum UpdateFlag: String, CustomStringConvertible {
        case applicationMenuFrame
        case desktopWallpaper

        var description: String { rawValue }
    }

    /// The kind of validation that occurs before an update.
    private enum ValidationKind {
        case showing
        case updates
    }

    /// A context that manages panel update tasks.
    @MainActor
    private final class UpdateTaskContext {
        private var tasks = [UpdateFlag: Task<Void, any Error>]()

        /// Sets the task for the given update flag.
        ///
        /// Setting the task cancels the previous task for the flag, if there is one.
        ///
        /// - Parameters:
        ///   - flag: The update flag to set the task for.
        ///   - operation: The operation for the task to perform.
        func setTask(for flag: UpdateFlag, operation: @escaping @MainActor () async throws -> Void) {
            cancelTask(for: flag)
            // NSPanel, NSScreen and the published drawing state belong to the
            // main actor. The operation uses a finite, cancellation-aware schedule.
            tasks[flag] = Task { @MainActor in
                try await operation()
            }
        }

        /// Cancels the task for the given update flag.
        ///
        /// - Parameter flag: The update flag to cancel the task for.
        func cancelTask(for flag: UpdateFlag) {
            tasks.removeValue(forKey: flag)?.cancel()
        }

        func cancelAll() {
            for task in tasks.values {
                task.cancel()
            }
            tasks.removeAll()
        }

        deinit {
            for task in tasks.values {
                task.cancel()
            }
        }
    }

    /// Shared logger for overlay panels.
    private static let logger = Logger(category: "MenuBarOverlayPanel")

    /// A Boolean value that indicates whether the panel needs to be shown.
    @Published var needsShow = false

    /// Flags representing the components of the panel currently in need of an update.
    @Published private(set) var updateFlags = Set<UpdateFlag>()

    /// The frame of the application menu.
    @Published private(set) var applicationMenuFrame: CGRect?

    /// The current desktop wallpaper, clipped to the bounds of the menu bar.
    @Published private(set) var desktopWallpaper: CGImage?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    private var periodicCancellables = Set<AnyCancellable>()

    /// The context that manages panel update tasks.
    private let updateTaskContext = UpdateTaskContext()

    /// One pending drain coalesces flags without losing updates to a later task.
    private var updateDrainTask: Task<Void, Never>?

    private var updatePolicy: MenuBarAppearanceUpdatePolicy
    private var isTornDown = false
    private var menuFrameReadCount = 0
    private var wallpaperCaptureCount = 0
    private var validationSkipCount = 0
    private var menuFrameReadNanoseconds: UInt64 = 0
    private var wallpaperCaptureNanoseconds: UInt64 = 0
    private var lastPerformanceLog = ContinuousClock.now

    /// The shared app state.
    private(set) weak var appState: AppState?

    /// The screen that owns the panel.
    let owningScreen: NSScreen

    /// Creates an overlay panel with the given app state and owning screen.
    init(appState: AppState, owningScreen: NSScreen, updatePolicy: MenuBarAppearanceUpdatePolicy) {
        self.appState = appState
        self.owningScreen = owningScreen
        self.updatePolicy = updatePolicy
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.level = .statusBar
        self.title = "Menu Bar Overlay"
        self.backgroundColor = .clear
        self.hasShadow = false
        self.animationBehavior = .none
        self.hidesOnDeactivate = false
        self.canHide = false
        self.isMovable = false
        self.ignoresMouseEvents = true
        self.isExcludedFromWindowsMenu = true
        self.collectionBehavior = [.fullScreenNone, .ignoresCycle, .moveToActiveSpace]
        self.contentView = MenuBarOverlayPanelContentView()
        configureCancellables()
    }

    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        // Show the panel on the active space.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .debounce(for: 0.1, scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.needsShow = true
            }
            .store(in: &c)

        // Update when light/dark mode changes.
        DistributedNotificationCenter.default()
            .publisher(for: DistributedNotificationCenter.interfaceThemeChangedNotification)
            .debounce(for: 0.1, scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else {
                    return
                }
                scheduleRefreshes(for: .desktopWallpaper, delays: MenuBarAppearanceUpdatePolicy.wallpaperRefreshDelays)
            }
            .store(in: &c)

        // Update application menu frame when the menu bar owning or frontmost app changes.
        Publishers.Merge(
            NSWorkspace.shared.publisher(for: \.menuBarOwningApplication, options: .old)
                .combineLatest(NSWorkspace.shared.publisher(for: \.menuBarOwningApplication, options: .new))
                .compactMap { $0 == $1 ? nil : $0 },
            NSWorkspace.shared.publisher(for: \.frontmostApplication, options: .old)
                .combineLatest(NSWorkspace.shared.publisher(for: \.frontmostApplication, options: .new))
                .compactMap { $0 == $1 ? nil : $0 }
        )
        .removeDuplicates()
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            guard let self else {
                return
            }
            scheduleRefreshes(for: .applicationMenuFrame, delays: MenuBarAppearanceUpdatePolicy.applicationMenuRefreshDelays)
        }
        .store(in: &c)

        // Special cases for when the user drags an app onto or clicks into another space.
        Publishers.Merge(
            publisher(for: \.isOnActiveSpace)
                .receive(on: DispatchQueue.main)
                .replace(with: ()),
            EventMonitor.publish(events: .leftMouseUp, scope: .universal)
                .filter { [weak self] _ in self?.isOnActiveSpace ?? false }
                .replace(with: ())
        )
        .debounce(for: 0.05, scheduler: DispatchQueue.main)
        .sink { [weak self] in
            self?.insertUpdateFlag(.applicationMenuFrame)
        }
        .store(in: &c)

        $needsShow
            .debounce(for: 0.05, scheduler: DispatchQueue.main)
            .sink { [weak self] needsShow in
                guard let self, needsShow else {
                    return
                }
                defer {
                    self.needsShow = false
                }
                show()
            }
            .store(in: &c)

        if let appState {
            appState.menuBarManager.$isMenuBarHiddenBySystem
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] isHidden in
                    guard let self, !isTornDown else { return }
                    alphaValue = isHidden ? 0 : 1
                    if !isHidden {
                        insertUpdateFlag(.applicationMenuFrame)
                        insertUpdateFlag(.desktopWallpaper)
                    }
                }
                .store(in: &c)
        }

        cancellables = c
        configurePeriodicUpdates()
    }

    private func configurePeriodicUpdates() {
        periodicCancellables.removeAll()
        guard !isTornDown else { return }
        // macOS has no reliable wallpaper-change notification. Keep the fallback
        // timer only for a drawing path that uses wallpaper, with coalescing leeway.
        if updatePolicy.needsDesktopWallpaper {
            Timer.publish(every: 5, tolerance: 1, on: .main, in: .default)
                .autoconnect()
                .sink { [weak self] _ in self?.insertUpdateFlag(.desktopWallpaper) }
                .store(in: &periodicCancellables)
        }
        if updatePolicy.needsApplicationMenuFrame {
            Timer.publish(every: 10, tolerance: 2, on: .main, in: .default)
                .autoconnect()
                .sink { [weak self] _ in self?.insertUpdateFlag(.applicationMenuFrame) }
                .store(in: &periodicCancellables)
        }
    }

    /// Inserts the given update flag into the panel's current list of update flags.
    private func insertUpdateFlag(_ flag: UpdateFlag) {
        guard shouldUpdate(flag) else { return }
        updateFlags.insert(flag)
        guard updateDrainTask == nil else { return }
        updateDrainTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self, !isTornDown else { return }
            defer { updateDrainTask = nil }
            let flags = updateFlags
            updateFlags.removeAll()
            let effectiveFlags = flags.filter { self.shouldUpdate($0) }
            guard !effectiveFlags.isEmpty else { return }
            let windows = WindowInfo.createWindows(option: .onScreen)
            if validate(for: .updates, with: windows) {
                performUpdates(for: effectiveFlags, windows: windows, screen: owningScreen)
            } else {
                validationSkipCount += 1
            }
            logPerformanceIfNeeded()
        }
    }

    private func shouldUpdate(_ flag: UpdateFlag) -> Bool {
        guard !isTornDown, isVisible, let appState else { return false }
        guard !appState.activeSpace.isFullscreen,
              !appState.menuBarManager.isMenuBarHiddenBySystemUserDefaults,
              !appState.menuBarManager.isMenuBarHiddenBySystem else { return false }
        switch flag {
        case .applicationMenuFrame: return updatePolicy.needsApplicationMenuFrame
        case .desktopWallpaper: return updatePolicy.needsDesktopWallpaper
        }
    }

    private func scheduleRefreshes(for flag: UpdateFlag, delays: [Duration]) {
        guard shouldUpdate(flag) else { return }
        updateTaskContext.setTask(for: flag) { [weak self] in
            try await MenuBarAppearanceUpdatePolicy.performRefreshes(delays: delays) { index in
                guard let self, self.shouldUpdate(flag) else { return false }
                // Keep the initial multi-display refresh; subsequent app-switch
                // settling checks are only useful for the active menu bar's screen.
                if flag == .applicationMenuFrame, index > 0, self.owningScreen != NSScreen.main {
                    return false
                }
                self.insertUpdateFlag(flag)
                return true
            }
        }
    }

    /// Reevaluate dependencies without replacing windows for every style edit.
    func applyUpdatePolicy(_ policy: MenuBarAppearanceUpdatePolicy) {
        guard !isTornDown else { return }
        let previousPolicy = updatePolicy
        updatePolicy = policy
        if previousPolicy.needsApplicationMenuFrame != policy.needsApplicationMenuFrame ||
            previousPolicy.needsDesktopWallpaper != policy.needsDesktopWallpaper {
            logPerformanceIfNeeded(force: true)
            AutomationDiagnosticLogger.shared.write(
                "APPEARANCE_POLICY display=\(owningScreen.displayID) " +
                "menuFrame=\(policy.needsApplicationMenuFrame) wallpaper=\(policy.needsDesktopWallpaper)"
            )
            configurePeriodicUpdates()
        }
        if !policy.needsApplicationMenuFrame {
            updateTaskContext.cancelTask(for: .applicationMenuFrame)
            updateFlags.remove(.applicationMenuFrame)
            applicationMenuFrame = nil
        } else if !previousPolicy.needsApplicationMenuFrame {
            insertUpdateFlag(.applicationMenuFrame)
        }
        if !policy.needsDesktopWallpaper {
            updateTaskContext.cancelTask(for: .desktopWallpaper)
            updateFlags.remove(.desktopWallpaper)
            desktopWallpaper = nil
        } else if !previousPolicy.needsDesktopWallpaper {
            insertUpdateFlag(.desktopWallpaper)
        }
        contentView?.needsDisplay = true
    }

    private func logPerformanceIfNeeded(force: Bool = false) {
        guard force || lastPerformanceLog.duration(to: .now) >= .seconds(60) else { return }
        guard menuFrameReadCount + wallpaperCaptureCount + validationSkipCount > 0 else { return }
        AutomationDiagnosticLogger.shared.write(
            "APPEARANCE_PERF display=\(owningScreen.displayID) menuFrameReads=\(menuFrameReadCount) " +
            "menuFrameMs=\(menuFrameReadNanoseconds / 1_000_000) wallpaperCaptures=\(wallpaperCaptureCount) " +
            "wallpaperMs=\(wallpaperCaptureNanoseconds / 1_000_000) validationSkipped=\(validationSkipCount)"
        )
        menuFrameReadCount = 0
        wallpaperCaptureCount = 0
        validationSkipCount = 0
        menuFrameReadNanoseconds = 0
        wallpaperCaptureNanoseconds = 0
        lastPerformanceLog = .now
    }

    /// Performs validation for the given validation kind. Returns the panel's
    /// owning display if successful. Returns `nil` on failure.
    private func validate(for kind: ValidationKind, with windows: [WindowInfo]) -> Bool {
        lazy var actionMessage = switch kind {
        case .showing: "Preventing overlay panel from showing."
        case .updates: "Preventing overlay panel from updating."
        }
        guard let appState else {
            MenuBarOverlayPanel.logger.debug("No app state. \(actionMessage, privacy: .public)")
            return false
        }
        guard !appState.menuBarManager.isMenuBarHiddenBySystemUserDefaults else {
            MenuBarOverlayPanel.logger.debug("Menu bar is hidden by system. \(actionMessage, privacy: .public)")
            return false
        }
        guard !appState.activeSpace.isFullscreen else {
            MenuBarOverlayPanel.logger.debug("Active space is fullscreen. \(actionMessage, privacy: .public)")
            return false
        }
        guard appState.menuBarManager.hasValidMenuBar(in: windows, for: owningScreen.displayID) else {
            MenuBarOverlayPanel.logger.debug("No valid menu bar found. \(actionMessage, privacy: .public)")
            return false
        }
        return true
    }

    /// Stores the frame of the menu bar's application menu.
    private func updateApplicationMenuFrame(for screen: NSScreen) {
        guard
            let menuBarManager = appState?.menuBarManager,
            !menuBarManager.isMenuBarHiddenBySystem
        else {
            return
        }
        let started = DispatchTime.now().uptimeNanoseconds
        defer { menuFrameReadNanoseconds += DispatchTime.now().uptimeNanoseconds - started }
        menuFrameReadCount += 1
        let frame = screen.getApplicationMenuFrame()
        if applicationMenuFrame != frame {
            applicationMenuFrame = frame
        }
    }

    /// Stores the area of the desktop wallpaper that is under the menu bar
    /// of the given display.
    private func updateDesktopWallpaper(for display: CGDirectDisplayID, with windows: [WindowInfo]) {
        guard
            let wallpaperWindow = WindowInfo.wallpaperWindow(from: windows, for: display),
            let menuBarWindow = WindowInfo.menuBarWindow(from: windows, for: display)
        else {
            return
        }
        let started = DispatchTime.now().uptimeNanoseconds
        defer { wallpaperCaptureNanoseconds += DispatchTime.now().uptimeNanoseconds - started }
        wallpaperCaptureCount += 1
        let wallpaper = ScreenCapture.captureWindow(with: wallpaperWindow.windowID, screenBounds: menuBarWindow.bounds)
        if desktopWallpaper?.dataProvider?.data != wallpaper?.dataProvider?.data {
            desktopWallpaper = wallpaper
        }
    }

    /// Updates the panel to prepare for display.
    private func performUpdates(for flags: Set<UpdateFlag>, windows: [WindowInfo], screen: NSScreen) {
        if flags.contains(.applicationMenuFrame) {
            updateApplicationMenuFrame(for: screen)
        }
        if flags.contains(.desktopWallpaper) {
            updateDesktopWallpaper(for: screen.displayID, with: windows)
        }
    }

    /// Shows the panel.
    private func show() {
        guard let appState, !isTornDown else {
            return
        }

        guard appState.appearanceManager.overlayPanels.contains(self) else {
            MenuBarOverlayPanel.logger.warning("Overlay panel \(self) not retained")
            return
        }

        // Validate before showing to ensure panel should be visible on this screen.
        let windows = WindowInfo.createWindows(option: .onScreen)
        guard validate(for: .showing, with: windows) else {
            return
        }

        guard let menuBarHeight = owningScreen.getMenuBarHeight() else {
            return
        }

        let newFrame = CGRect(
            x: owningScreen.frame.minX,
            y: (owningScreen.frame.maxY - menuBarHeight) - 5,
            width: owningScreen.frame.width,
            height: menuBarHeight + 5
        )

        alphaValue = 0
        setFrame(newFrame, display: false)
        orderFrontRegardless()

        insertUpdateFlag(.applicationMenuFrame)
        insertUpdateFlag(.desktopWallpaper)

        if !appState.menuBarManager.isMenuBarHiddenBySystem {
            animator().alphaValue = 1
        }
    }

    override func isAccessibilityElement() -> Bool {
        return false
    }

    override func close() {
        guard !isTornDown else { return }
        isTornDown = true
        updateTaskContext.cancelAll()
        updateDrainTask?.cancel()
        updateDrainTask = nil
        cancellables.removeAll()
        periodicCancellables.removeAll()
        updateFlags.removeAll()
        logPerformanceIfNeeded(force: true)
        desktopWallpaper = nil
        applicationMenuFrame = nil
        contentView = nil
        super.close()
    }
}

// MARK: - Content View

private final class MenuBarOverlayPanelContentView: NSView {
    @Published private var fullConfiguration: MenuBarAppearanceConfigurationV2 = .defaultConfiguration

    @Published private var previewConfiguration: MenuBarAppearancePartialConfiguration?

    private var cancellables = Set<AnyCancellable>()

    /// The overlay panel that contains the content view.
    private var overlayPanel: MenuBarOverlayPanel? {
        window as? MenuBarOverlayPanel
    }

    /// The currently displayed configuration.
    private var configuration: MenuBarAppearancePartialConfiguration {
        previewConfiguration ?? fullConfiguration.current
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureCancellables()
    }

    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        if let overlayPanel {
            if let appState = overlayPanel.appState {
                appState.appearanceManager.$configuration
                    .removeDuplicates()
                    .assign(to: &$fullConfiguration)

                appState.appearanceManager.$previewConfiguration
                    .removeDuplicates()
                    .assign(to: &$previewConfiguration)

                // Fade out whenever a menu bar item is being dragged.
                appState.$isDraggingMenuBarItem
                    .removeDuplicates()
                    .sink { [weak self] isDragging in
                        if isDragging {
                            self?.animator().alphaValue = 0
                        } else {
                            self?.animator().alphaValue = 1
                        }
                    }
                    .store(in: &c)

                for section in appState.menuBarManager.sections {
                    // Redraw whenever the window frame of a control item changes.
                    //
                    // - NOTE: A previous attempt was made to redraw the view when the
                    //   section's `isHidden` property was changed. This would be semantically
                    //   ideal, but the property sometimes changes before the menu bar items
                    //   are actually updated on-screen. Since the view's drawing process relies
                    //   on getting an accurate position of each menu bar item, we need to use
                    //   something that publishes its changes only after the items are updated.
                    section.controlItem.$onScreenFrame
                        .receive(on: DispatchQueue.main)
                        .sink { [weak self] _ in
                            self?.needsDisplay = true
                        }
                        .store(in: &c)
                }
            }

            // Redraw whenever the application menu frame changes.
            overlayPanel.$applicationMenuFrame
                .sink { [weak self] _ in
                    self?.needsDisplay = true
                }
                .store(in: &c)
            // Redraw whenever the desktop wallpaper changes.
            overlayPanel.$desktopWallpaper
                .sink { [weak self] _ in
                    self?.needsDisplay = true
                }
                .store(in: &c)
        }

        // Redraw whenever the configurations change.
        $fullConfiguration.replace(with: ())
            .merge(with: $previewConfiguration.replace(with: ()))
            .sink { [weak self] _ in
                self?.needsDisplay = true
            }
            .store(in: &c)

        cancellables = c
    }

    /// Returns a path in the given rectangle, with the given end caps,
    /// and inset by the given amounts.
    private func shapePath(in rect: CGRect, leadingEndCap: MenuBarEndCap, trailingEndCap: MenuBarEndCap, screen: NSScreen) -> NSBezierPath {
        let insetRect: CGRect = if !screen.hasNotch {
            switch (leadingEndCap, trailingEndCap) {
            case (.square, .square):
                CGRect(x: rect.origin.x, y: rect.origin.y + 1, width: rect.width, height: rect.height - 2)
            case (.square, .round):
                CGRect(x: rect.origin.x, y: rect.origin.y + 1, width: rect.width - 1, height: rect.height - 2)
            case (.round, .square):
                CGRect(x: rect.origin.x + 1, y: rect.origin.y + 1, width: rect.width - 1, height: rect.height - 2)
            case (.round, .round):
                CGRect(x: rect.origin.x + 1, y: rect.origin.y + 1, width: rect.width - 2, height: rect.height - 2)
            }
        } else {
            rect
        }

        let shapeBounds = CGRect(
            x: insetRect.minX + insetRect.height / 2,
            y: insetRect.minY,
            width: insetRect.width - insetRect.height,
            height: insetRect.height
        )
        let leadingEndCapBounds = CGRect(
            x: insetRect.minX,
            y: insetRect.minY,
            width: insetRect.height,
            height: insetRect.height
        )
        let trailingEndCapBounds = CGRect(
            x: insetRect.maxX - insetRect.height,
            y: insetRect.minY,
            width: insetRect.height,
            height: insetRect.height
        )

        var path = NSBezierPath(rect: shapeBounds)

        path = switch leadingEndCap {
        case .square: path.union(NSBezierPath(rect: leadingEndCapBounds))
        case .round: path.union(NSBezierPath(ovalIn: leadingEndCapBounds))
        }

        path = switch trailingEndCap {
        case .square: path.union(NSBezierPath(rect: trailingEndCapBounds))
        case .round: path.union(NSBezierPath(ovalIn: trailingEndCapBounds))
        }

        return path
    }

    /// Returns a path for the ``MenuBarShapeKind/full`` shape kind.
    private func pathForFullShape(in rect: CGRect, info: MenuBarFullShapeInfo, isInset: Bool, screen: NSScreen) -> NSBezierPath {
        guard let appearanceManager = overlayPanel?.appState?.appearanceManager else {
            return NSBezierPath()
        }
        var rect = rect
        let shouldInset = isInset && screen.hasNotch
        if shouldInset {
            rect = rect.insetBy(dx: 0, dy: appearanceManager.menuBarInsetAmount)
            if info.leadingEndCap == .round {
                rect.origin.x += appearanceManager.menuBarInsetAmount
                rect.size.width -= appearanceManager.menuBarInsetAmount
            }
            if info.trailingEndCap == .round {
                rect.size.width -= appearanceManager.menuBarInsetAmount
            }
        }
        return shapePath(
            in: rect,
            leadingEndCap: info.leadingEndCap,
            trailingEndCap: info.trailingEndCap,
            screen: screen
        )
    }

    /// Returns a path for the ``MenuBarShapeKind/split`` shape kind.
    private func pathForSplitShape(in rect: CGRect, info: MenuBarSplitShapeInfo, isInset: Bool, screen: NSScreen) -> NSBezierPath {
        guard let appearanceManager = overlayPanel?.appState?.appearanceManager else {
            return NSBezierPath()
        }
        var rect = rect
        let shouldInset = isInset && screen.hasNotch
        if shouldInset {
            rect = rect.insetBy(dx: 0, dy: appearanceManager.menuBarInsetAmount)
            if info.leading.leadingEndCap == .round {
                rect.origin.x += appearanceManager.menuBarInsetAmount
                rect.size.width -= appearanceManager.menuBarInsetAmount
            }
            if info.trailing.trailingEndCap == .round {
                rect.size.width -= appearanceManager.menuBarInsetAmount
            }
        }
        let leadingPathBounds: CGRect = {
            guard
                var maxX = overlayPanel?.applicationMenuFrame?.width,
                maxX > 0
            else {
                return .zero
            }
            if shouldInset {
                maxX += 10
                if info.leading.leadingEndCap == .square {
                    maxX += appearanceManager.menuBarInsetAmount
                }
            } else {
                maxX += 20
            }
            return CGRect(x: rect.minX, y: rect.minY, width: maxX, height: rect.height)
        }()
        let trailingPathBounds: CGRect = {
            let itemWindows = MenuBarItem.getMenuBarItemWindows(on: screen.displayID, option: .onScreen)
            guard !itemWindows.isEmpty else {
                return .zero
            }
            let totalWidth = itemWindows.reduce(into: 0) { width, item in
                width += item.bounds.width
            }
            var position = rect.maxX - totalWidth
            if shouldInset {
                position += 4
                if info.trailing.trailingEndCap == .square {
                    position -= appearanceManager.menuBarInsetAmount
                }
            } else {
                position -= 7
            }
            return CGRect(x: position, y: rect.minY, width: rect.maxX - position, height: rect.height)
        }()

        if leadingPathBounds == .zero || trailingPathBounds == .zero || leadingPathBounds.intersects(trailingPathBounds) {
            return shapePath(
                in: rect,
                leadingEndCap: info.leading.leadingEndCap,
                trailingEndCap: info.trailing.trailingEndCap,
                screen: screen
            )
        } else {
            let leadingPath = shapePath(
                in: leadingPathBounds,
                leadingEndCap: info.leading.leadingEndCap,
                trailingEndCap: info.leading.trailingEndCap,
                screen: screen
            )
            let trailingPath = shapePath(
                in: trailingPathBounds,
                leadingEndCap: info.trailing.leadingEndCap,
                trailingEndCap: info.trailing.trailingEndCap,
                screen: screen
            )
            let path = NSBezierPath()
            path.append(leadingPath)
            path.append(trailingPath)
            return path
        }
    }

    /// Returns the bounds that the view's drawn content can occupy.
    private func getDrawableBounds() -> CGRect {
        return CGRect(
            x: bounds.origin.x,
            y: bounds.origin.y + 5,
            width: bounds.width,
            height: bounds.height - 5
        )
    }

    /// Draws the tint defined by the given configuration in the given rectangle.
    private func drawTint(in rect: CGRect) {
        switch configuration.tintKind {
        case .noTint:
            break
        case .solid:
            if let tintColor = NSColor(cgColor: configuration.tintColor)?.withAlphaComponent(0.2) {
                tintColor.setFill()
                rect.fill()
            }
        case .gradient:
            if let tintGradient = configuration.tintGradient.withAlpha(0.2).nsGradient(using: .displayP3) {
                tintGradient.draw(in: rect, angle: 0)
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard
            let overlayPanel,
            let context = NSGraphicsContext.current
        else {
            return
        }

        let drawableBounds = getDrawableBounds()

        let shapePath = switch fullConfiguration.shapeKind {
        case .noShape:
            NSBezierPath(rect: drawableBounds)
        case .full:
            pathForFullShape(
                in: drawableBounds,
                info: fullConfiguration.fullShapeInfo,
                isInset: fullConfiguration.isInset,
                screen: overlayPanel.owningScreen
            )
        case .split:
            pathForSplitShape(
                in: drawableBounds,
                info: fullConfiguration.splitShapeInfo,
                isInset: fullConfiguration.isInset,
                screen: overlayPanel.owningScreen
            )
        }

        var hasBorder = false

        switch fullConfiguration.shapeKind {
        case .noShape:
            if configuration.hasShadow {
                let gradient = NSGradient(
                    colors: [
                        NSColor(white: 0.0, alpha: 0.0),
                        NSColor(white: 0.0, alpha: 0.2),
                    ]
                )
                let shadowBounds = CGRect(
                    x: bounds.minX,
                    y: bounds.minY,
                    width: bounds.width,
                    height: 5
                )
                gradient?.draw(in: shadowBounds, angle: 90)
            }

            drawTint(in: drawableBounds)

            if configuration.hasBorder {
                let borderBounds = CGRect(
                    x: bounds.minX,
                    y: bounds.minY + 5,
                    width: bounds.width,
                    height: configuration.borderWidth
                )
                NSColor(cgColor: configuration.borderColor)?.setFill()
                NSBezierPath(rect: borderBounds).fill()
            }
        case .full, .split:
            if let desktopWallpaper = overlayPanel.desktopWallpaper {
                context.saveGraphicsState()
                defer {
                    context.restoreGraphicsState()
                }

                let invertedClipPath = NSBezierPath(rect: drawableBounds)
                invertedClipPath.append(shapePath.reversed)
                invertedClipPath.setClip()

                context.cgContext.draw(desktopWallpaper, in: drawableBounds)
            }

            if configuration.hasShadow {
                context.saveGraphicsState()
                defer {
                    context.restoreGraphicsState()
                }

                let shadowClipPath = NSBezierPath(rect: bounds)
                shadowClipPath.append(shapePath.reversed)
                shadowClipPath.setClip()

                shapePath.drawShadow(color: .black.withAlphaComponent(0.5), radius: 5)
            }

            if configuration.hasBorder {
                hasBorder = true
            }

            do {
                context.saveGraphicsState()
                defer {
                    context.restoreGraphicsState()
                }

                shapePath.setClip()

                drawTint(in: drawableBounds)
            }

            if
                hasBorder,
                let borderColor = NSColor(cgColor: configuration.borderColor)
            {
                context.saveGraphicsState()
                defer {
                    context.restoreGraphicsState()
                }

                let borderPath = switch fullConfiguration.shapeKind {
                case .noShape:
                    NSBezierPath(rect: drawableBounds)
                case .full:
                    pathForFullShape(
                        in: drawableBounds,
                        info: fullConfiguration.fullShapeInfo,
                        isInset: fullConfiguration.isInset,
                        screen: overlayPanel.owningScreen
                    )
                case .split:
                    pathForSplitShape(
                        in: drawableBounds,
                        info: fullConfiguration.splitShapeInfo,
                        isInset: fullConfiguration.isInset,
                        screen: overlayPanel.owningScreen
                    )
                }

                // HACK: Insetting a path to get an "inside" stroke is surprisingly
                // difficult. We can fake the correct line width by doubling it, as
                // anything outside the shape path will be clipped.
                borderPath.lineWidth = configuration.borderWidth * 2
                borderPath.setClip()

                borderColor.setStroke()
                borderPath.stroke()
            }
        }
    }
}
