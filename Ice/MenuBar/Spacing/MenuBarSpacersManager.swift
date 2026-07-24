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
    static let autosaveNamePrefix = "IceSpacer-"

    /// The status items for the current spacers, keyed by spacer ID.
    private var statusItems = [UUID: NSStatusItem]()

    /// The shared app state.
    private(set) weak var appState: AppState?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    private let logger = Logger(category: "MenuBarSpacersManager")

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
        for (id, statusItem) in statusItems where !validIDs.contains(id) {
            logger.info("Removing spacer \(id.uuidString, privacy: .public)")
            NSStatusBar.system.removeStatusItem(statusItem)
            statusItems.removeValue(forKey: id)
        }

        // Create or update the rest.
        for spacer in spacers {
            let statusItem = statusItems[spacer.id] ?? createStatusItem(for: spacer)
            statusItem.length = CGFloat(spacer.width)
            configureButton(of: statusItem, showMarkers: showMarkers)
        }
    }

    private func createStatusItem(for spacer: GeneralSettings.MenuBarSpacer) -> NSStatusItem {
        logger.info("Creating spacer \(spacer.id.uuidString, privacy: .public) with width \(spacer.width, privacy: .public)")

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

    /// An error thrown when a spacer cannot be repositioned.
    struct RepositionError: Error, CustomStringConvertible {
        let description: String
    }

    /// Moves a spacer to the given destination by seeding its preferred
    /// position and recreating its status item.
    ///
    /// Ice's normal move machinery synthesizes mouse events targeted at
    /// the item's owning process — which for spacers is Ice itself. That
    /// deadlocks against the very operation awaiting it, times out, and
    /// sprays stray events into the menu bar. Since Ice owns the spacer,
    /// no events are needed at all: write the position macOS should use
    /// and recreate the item, the same mechanism used at every launch.
    func repositionSpacer(item: MenuBarItem, to destination: MenuBarItemManager.MoveDestination) throws {
        let title = item.tag.title
        guard
            title.hasPrefix(Self.autosaveNamePrefix),
            let id = UUID(uuidString: String(title.dropFirst(Self.autosaveNamePrefix.count))),
            let statusItem = statusItems[id],
            let spacer = appState?.settings.general.menuBarSpacers.first(where: { $0.id == id })
        else {
            throw RepositionError(description: "No managed spacer for tag \(item.tag)")
        }

        let target = destination.targetItem

        // Preferred positions are measured from the right edge of the
        // screen to the item's left edge. Choosing a value 1 point inside
        // the target's own edge sorts the spacer directly next to it.
        guard let screen = NSScreen.screens.first(where: { screen in
            screen.frame.minX <= target.bounds.midX && target.bounds.midX <= screen.frame.maxX
        }) ?? NSScreen.main else {
            throw RepositionError(description: "No screen for target item \(target.tag)")
        }

        let position: CGFloat = switch destination {
        case .leftOfItem:
            screen.frame.maxX - target.bounds.minX + 1
        case .rightOfItem:
            screen.frame.maxX - target.bounds.maxX + 1
        }

        logger.info(
            """
            Repositioning spacer \(id.uuidString, privacy: .public) to preferred \
            position \(position, format: .fixed(precision: 1), privacy: .public)
            """
        )

        let autosaveName = Self.autosaveNamePrefix + id.uuidString
        let showMarkers = appState?.settings.general.showSpacerMarkers ?? true

        // Removing a status item clears its stored position, so write the
        // new position after removal, then recreate the item.
        NSStatusBar.system.removeStatusItem(statusItem)
        statusItems.removeValue(forKey: id)
        ControlItemDefaults[.preferredPosition, autosaveName] = position

        let newStatusItem = NSStatusBar.system.statusItem(withLength: CGFloat(spacer.width))
        newStatusItem.autosaveName = autosaveName
        statusItems[id] = newStatusItem
        configureButton(of: newStatusItem, showMarkers: showMarkers)
    }

    private func configureButton(of statusItem: NSStatusItem, showMarkers: Bool) {
        guard let button = statusItem.button else {
            return
        }
        if showMarkers {
            let image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Spacer")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 6, weight: .bold))
            button.image = image
            button.alphaValue = 0.5
        } else {
            button.image = nil
            button.alphaValue = 1
        }
    }
}
