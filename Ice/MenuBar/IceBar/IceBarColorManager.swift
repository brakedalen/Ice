//
//  IceBarColorManager.swift
//  Ice
//

import Combine
import SwiftUI

@MainActor
final class IceBarColorManager: ObservableObject {
    @Published private(set) var colorInfo: MenuBarAverageColorInfo?

    private weak var iceBarPanel: IceBarPanel?

    private var windowImage: CGImage?
    private var windowImageDisplayID: CGDirectDisplayID?
    private var needsWindowImage = true
    private var periodicCapture: AnyCancellable?
    private var captureCount = 0
    private var captureFailureCount = 0
    private var captureNanoseconds: UInt64 = 0
    private var lastPerformanceLog = ContinuousClock.now

    private var cancellables = Set<AnyCancellable>()

    func performSetup(with iceBarPanel: IceBarPanel) {
        self.iceBarPanel = iceBarPanel
        configureCancellables()
    }

    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        if let iceBarPanel {
            iceBarPanel.publisher(for: \.screen)
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak iceBarPanel] screen in
                    guard
                        let self,
                        let iceBarPanel,
                        let screen,
                        screen == iceBarPanel.screen,
                        iceBarPanel.isVisible,
                        screen == .main
                    else {
                        return
                    }
                    updateWindowImage(for: screen)
                    updateColorInfo(with: iceBarPanel.frame, screen: screen)
                }
                .store(in: &c)

            iceBarPanel.publisher(for: \.isVisible)
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak iceBarPanel] isVisible in
                    guard let self, let iceBarPanel, isVisible == iceBarPanel.isVisible else {
                        return
                    }
                    configurePeriodicCapture(isVisible: isVisible)
                    guard isVisible else {
                        windowImage = nil
                        windowImageDisplayID = nil
                        needsWindowImage = true
                        logPerformanceIfNeeded()
                        return
                    }
                    guard let screen = iceBarPanel.screen, screen == .main else { return }
                    // show() normally captured immediately before ordering the panel
                    // front. Only recapture if it was not prepared for this screen.
                    if needsWindowImage || windowImageDisplayID != screen.displayID {
                        updateWindowImage(for: screen)
                    }
                    updateColorInfo(with: iceBarPanel.frame, screen: screen)
                }
                .store(in: &c)

            iceBarPanel.publisher(for: \.frame)
                .throttle(for: 0.1, scheduler: DispatchQueue.main, latest: true)
                .sink { [weak self, weak iceBarPanel] frame in
                    guard
                        let self,
                        let iceBarPanel,
                        let screen = iceBarPanel.screen,
                        iceBarPanel.isVisible,
                        screen == .main
                    else {
                        return
                    }
                    withAnimation(.interactiveSpring) {
                        self.updateColorInfo(with: frame, screen: screen)
                    }
                }
                .store(in: &c)

            Publishers.Merge3(
                NSWorkspace.shared.notificationCenter
                    .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
                    .replace(with: ()),
                NotificationCenter.default
                    .publisher(for: NSApplication.didChangeScreenParametersNotification)
                    .replace(with: ()),
                DistributedNotificationCenter.default()
                    .publisher(for: DistributedNotificationCenter.interfaceThemeChangedNotification)
                    .replace(with: ())
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak iceBarPanel] in
                guard
                    let self,
                    let iceBarPanel
                else {
                    return
                }
                needsWindowImage = true
                refreshVisiblePanel(iceBarPanel)
            }
            .store(in: &c)
        }

        cancellables = c
    }

    private func configurePeriodicCapture(isVisible: Bool) {
        periodicCapture?.cancel()
        periodicCapture = nil
        guard isVisible else { return }
        periodicCapture = Timer.publish(every: 5, tolerance: 1, on: .main, in: .default)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, let iceBarPanel else { return }
                refreshVisiblePanel(iceBarPanel)
            }
    }

    private func refreshVisiblePanel(_ panel: IceBarPanel) {
        guard panel.isVisible, let screen = panel.screen, screen == .main else { return }
        updateWindowImage(for: screen)
        withAnimation {
            updateColorInfo(with: panel.frame, screen: screen)
        }
    }

    private func updateWindowImage(for screen: NSScreen) {
        let started = DispatchTime.now().uptimeNanoseconds
        defer {
            captureNanoseconds += DispatchTime.now().uptimeNanoseconds - started
            logPerformanceIfNeeded()
        }
        let displayID = screen.displayID
        if windowImageDisplayID != displayID {
            // Never reuse the previous monitor's color after a display change.
            windowImage = nil
            colorInfo = nil
        }
        let windows = WindowInfo.createWindows(option: .onScreen)

        guard
            let menuBarWindow = WindowInfo.menuBarWindow(from: windows, for: displayID),
            let wallpaperWindow = WindowInfo.wallpaperWindow(from: windows, for: displayID)
        else {
            captureFailureCount += 1
            return
        }

        guard let image = ScreenCapture.captureWindows(
            with: [menuBarWindow.windowID, wallpaperWindow.windowID],
            screenBounds: withMutableCopy(of: wallpaperWindow.bounds) { $0.size.height = 1 },
            option: .nominalResolution
        ) else {
            captureFailureCount += 1
            return
        }

        captureCount += 1
        windowImage = image
        windowImageDisplayID = displayID
        needsWindowImage = false
    }

    private func updateColorInfo(with frame: CGRect, screen: NSScreen) {
        guard let image = windowImage, windowImageDisplayID == screen.displayID else {
            return
        }

        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)

        let percentage = Self.samplePercentage(for: frame, in: screen.frame)

        let cropRect = CGRect(x: imageBounds.width * percentage, y: 0, width: 0, height: 1)
            .insetBy(dx: -150, dy: 0)
            .intersection(imageBounds)

        guard
            let croppedImage = image.cropping(to: cropRect),
            let averageColor = croppedImage.averageColor()
        else {
            return
        }

        // Just use `menuBarWindow` as the source for now, regardless
        // of whether its image contributed to the average.
        colorInfo = MenuBarAverageColorInfo(color: averageColor, source: .menuBarWindow)
    }

    /// A row as wide as its screen has no horizontal travel; sample its center
    /// rather than passing NaN/infinity into Core Graphics' cropping rectangle.
    static func samplePercentage(for frame: CGRect, in screenFrame: CGRect) -> CGFloat {
        let availableWidth = screenFrame.width - frame.width
        guard availableWidth > 0 else { return 0.5 }
        let leadingCenter = screenFrame.minX + frame.width / 2
        return ((frame.midX - leadingCenter) / availableWidth).clamped(to: 0...1)
    }

    func updateAllProperties(with frame: CGRect, screen: NSScreen) {
        // Explicit pre-show preparation is intentional. Background event/timer
        // paths are visibility-gated, but this prevents a stale-color first frame.
        updateWindowImage(for: screen)
        updateColorInfo(with: frame, screen: screen)
    }

    private func logPerformanceIfNeeded() {
        guard lastPerformanceLog.duration(to: .now) >= .seconds(60) else { return }
        guard captureCount + captureFailureCount > 0 else { return }
        AutomationDiagnosticLogger.shared.write(
            "ICE_BAR_COLOR_PERF captures=\(captureCount) failed=\(captureFailureCount) " +
            "durationMs=\(captureNanoseconds / 1_000_000) visible=\(iceBarPanel?.isVisible ?? false)"
        )
        captureCount = 0
        captureFailureCount = 0
        captureNanoseconds = 0
        lastPerformanceLog = .now
    }
}
