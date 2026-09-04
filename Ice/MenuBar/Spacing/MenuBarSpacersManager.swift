//
//  MenuBarSpacersManager.swift
//  Ice
//

import Cocoa
import Combine
import OSLog

// MARK: - MenuBarItemTag + isIceSpacer

extension MenuBarItemTag {
    /// A Boolean value that indicates whether the item identified by
    /// this tag is a menu bar spacer owned by Ice.
    var isIceSpacer: Bool {
        namespace == .ice && title.hasPrefix(MenuBarSpacersManager.autosaveNamePrefix)
    }

    /// The identifier of the spacer represented by this tag, or `nil`
    /// if the tag does not represent a spacer.
    var iceSpacerID: UUID? {
        guard isIceSpacer else {
            return nil
        }
        return UUID(uuidString: String(title.dropFirst(MenuBarSpacersManager.autosaveNamePrefix.count)))
    }
}

/// Manages the user's menu bar spacers.
///
/// A spacer is an empty status item with a fixed width, used to insert
/// blank space between menu bar items so they can be grouped visually.
/// Spacers are plain `NSStatusItem`s — the same primitive Ice's own
/// section dividers are built on — so macOS itself persists their
/// position across launches via their autosave names.
@MainActor
final class MenuBarSpacersManager {
    /// The prefix used for spacer autosave names.
    ///
    /// Nonisolated so the tag helpers above can read it from any context;
    /// it is an immutable constant, which makes that safe.
    nonisolated static let autosaveNamePrefix = "IceSpacer-"

    /// The status items for the current spacers, keyed by spacer ID.
    private var statusItems = [UUID: NSStatusItem]()

    /// The shared app state.
    private(set) weak var appState: AppState?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    private let logger = Logger(category: "MenuBarSpacersManager")

    private let diagnosticLogger = AutomationDiagnosticLogger.shared

    /// Performs the initial setup of the manager.
    func performSetup(with appState: AppState) {
        self.appState = appState

        let settings = appState.settings.general

        Publishers.CombineLatest(
            settings.$menuBarSpacers,
            settings.$showSpacerMarkers
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] spacers, showMarkers in
            self?.reconcile(spacers: spacers, showMarkers: showMarkers)
        }
        .store(in: &cancellables)
    }

    /// Brings the actual status items in sync with the given
    /// configuration.
    private func reconcile(spacers: [GeneralSettings.MenuBarSpacer], showMarkers: Bool) {
        // Remove status items for deleted spacers.
        let validIDs = Set(spacers.map { $0.id })
        for id in statusItems.keys.filter({ !validIDs.contains($0) }) {
            guard let statusItem = statusItems[id] else {
                continue
            }
            logger.info("Removing spacer \(id.uuidString, privacy: .public)")
            diagnosticLogger.write("SPACER_REMOVE id=\(id.uuidString) reason=settings")
            NSStatusBar.system.removeStatusItem(statusItem)
            statusItems.removeValue(forKey: id)
        }

        // Create or update the rest.
        for (index, spacer) in spacers.enumerated() {
            let statusItem = statusItems[spacer.id] ?? createStatusItem(for: spacer)
            statusItem.length = CGFloat(spacer.width)
            configureButton(of: statusItem, number: index + 1, showMarkers: showMarkers)
        }
    }

    private func createStatusItem(for spacer: GeneralSettings.MenuBarSpacer) -> NSStatusItem {
        logger.info("Creating spacer \(spacer.id.uuidString, privacy: .public) with width \(spacer.width, privacy: .public)")
        diagnosticLogger.write(
            "SPACER_CREATE id=\(spacer.id.uuidString) width=\(spacer.width)"
        )

        let autosaveName = Self.autosaveNamePrefix + spacer.id.uuidString

        // New status items are inserted at the far left of the menu bar,
        // which is inside the hidden (or always-hidden) section — where a
        // brand new spacer would be invisible. Seed the preferred position
        // of first-time spacers to just inside the visible section, so the
        // user immediately sees what they created and can drag it from
        // there.
        if ControlItemDefaults[.preferredPosition, autosaveName] == nil {
            let hiddenDividerPosition = ControlItemDefaults[
                .preferredPosition,
                ControlItem.Identifier.hidden.rawValue
            ]
            if let hiddenDividerPosition {
                ControlItemDefaults[.preferredPosition, autosaveName] = max(hiddenDividerPosition - 1, 0)
            }
        }

        let statusItem = NSStatusBar.system.statusItem(withLength: CGFloat(spacer.width))
        statusItem.autosaveName = autosaveName
        statusItems[spacer.id] = statusItem
        return statusItem
    }

    private func configureButton(of statusItem: NSStatusItem, number: Int, showMarkers: Bool) {
        guard let button = statusItem.button else {
            return
        }
        if showMarkers {
            button.attributedTitle = NSAttributedString(
                string: String(number),
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)]
            )
            button.alphaValue = 0.5
        } else {
            button.attributedTitle = NSAttributedString(string: "")
            button.alphaValue = 1
        }
    }
}
