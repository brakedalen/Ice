//
//  MenuBarAppearanceManager.swift
//  Ice
//

import Cocoa
import Combine
import OSLog

/// A manager for the appearance of the menu bar.
@MainActor
final class MenuBarAppearanceManager: ObservableObject {
    /// The current menu bar appearance configuration.
    @Published var configuration: MenuBarAppearanceConfigurationV2 = .defaultConfiguration

    /// The currently previewed partial configuration.
    @Published var previewConfiguration: MenuBarAppearancePartialConfiguration?

    /// The shared app state.
    private weak var appState: AppState?

    /// Encoder for UserDefaults values.
    private let encoder = JSONEncoder()

    /// Decoder for UserDefaults values.
    private let decoder = JSONDecoder()

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// The currently managed menu bar overlay panels.
    private(set) var overlayPanels = Set<MenuBarOverlayPanel>()

    /// The amount to inset the menu bar if called for by the configuration.
    let menuBarInsetAmount: CGFloat = if #available(macOS 26.0, *) { 3.5 } else { 5 }

    /// Performs initial setup of the manager.
    func performSetup(with appState: AppState) {
        self.appState = appState
        loadInitialState()
        configureCancellables()
    }

    /// Loads the initial values for the configuration.
    private func loadInitialState() {
        do {
            if let data = Defaults.data(forKey: .menuBarAppearanceConfigurationV2) {
                configuration = try decoder.decode(MenuBarAppearanceConfigurationV2.self, from: data)
            }
        } catch {
            Logger.serialization.error("Error decoding menu bar appearance configuration: \(error)")
        }
    }

    /// Configures the internal observers for the manager.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: 0.1, scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else {
                    return
                }
                // NSScreen objects can keep the same identity while their geometry
                // changes. Rebuild for a display change and tear down all old work.
                reconcileOverlayPanels(configuration: configuration, preview: previewConfiguration, rebuild: true)
            }
            .store(in: &c)

        $configuration
            .encode(encoder: encoder)
            .receive(on: DispatchQueue.main)
            .sink { completion in
                if case .failure(let error) = completion {
                    Logger.serialization.error("Error encoding menu bar appearance configuration: \(error)")
                }
            } receiveValue: { data in
                Defaults.set(data, forKey: .menuBarAppearanceConfigurationV2)
            }
            .store(in: &c)

        $configuration.combineLatest($previewConfiguration)
            // @Published emits in willSet. Defer reconciliation until both stored
            // properties are committed, so a new content view sees the same state.
            .receive(on: DispatchQueue.main)
            .throttle(for: 0.1, scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] configuration, preview in
                guard let self else {
                    return
                }
                reconcileOverlayPanels(configuration: configuration, preview: preview)
            }
            .store(in: &c)

        // A dynamic configuration may need panels in only one system appearance.
        DistributedNotificationCenter.default()
            .publisher(for: DistributedNotificationCenter.interfaceThemeChangedNotification)
            .debounce(for: 0.1, scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                reconcileOverlayPanels(configuration: configuration, preview: previewConfiguration)
            }
            .store(in: &c)

        cancellables = c
    }

    /// Reconciles panel lifetime with the effective appearance, including previews.
    private func reconcileOverlayPanels(
        configuration: MenuBarAppearanceConfigurationV2,
        preview: MenuBarAppearancePartialConfiguration?,
        rebuild: Bool = false
    ) {
        let policy = MenuBarAppearanceUpdatePolicy(configuration: configuration, preview: preview)
        let previousCount = overlayPanels.count
        if rebuild || !policy.needsOverlay || appState == nil {
            while let panel = overlayPanels.popFirst() {
                panel.close()
            }
        }

        if let appState, policy.needsOverlay {
            if overlayPanels.isEmpty {
                for screen in NSScreen.screens {
                    let panel = MenuBarOverlayPanel(appState: appState, owningScreen: screen, updatePolicy: policy)
                    overlayPanels.insert(panel)
                    panel.needsShow = true
                }
            } else {
                for panel in overlayPanels {
                    panel.applyUpdatePolicy(policy)
                }
            }
        }

        if rebuild || previousCount != overlayPanels.count {
            AutomationDiagnosticLogger.shared.write(
                "APPEARANCE_PANELS previous=\(previousCount) current=\(overlayPanels.count) " +
                "rebuild=\(rebuild) menuFrame=\(policy.needsApplicationMenuFrame) wallpaper=\(policy.needsDesktopWallpaper)"
            )
        }
    }
}
