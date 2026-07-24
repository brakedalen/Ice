//
//  AutomationManager.swift
//  Ice
//

import Combine
import Foundation
import OSLog

// MARK: - MenuBarItemTag + automationKey

extension MenuBarItemTag {
    /// A stable string key for persisting references to this item, or
    /// `nil` if the item has no stable identity across launches.
    ///
    /// Only items namespaced by a string (in practice, a bundle
    /// identifier) are stable across app and system restarts. Items with
    /// UUID namespaces get a new identity every launch and cannot be
    /// meaningfully remembered.
    var automationKey: String? {
        guard
            case .string(let string) = namespace,
            !isControlItem,
            !isSystemClone
        else {
            return nil
        }
        return string + "\u{1F}" + title
    }
}

// MARK: - AutomationManager

/// Manages automatic placement of menu bar items.
///
/// Two responsibilities:
///
/// 1. **Placement memory:** remembers which section each menu bar item
///    belongs to and restores items that reappear in the wrong section.
///    Apps like OneDrive recreate their status item on every launch
///    without a saved position, which makes macOS insert it at the far
///    left of the menu bar — the hidden or always-hidden section
///    (upstream issue #909).
/// 2. **Rules:** shows or hides selected items when a system condition
///    (Wi-Fi connectivity, external power) changes.
///
/// Design notes for reliability: this type only ever *observes*
/// passively (Combine publishers, debounced) and funnels every mutation
/// through ``enforceDesiredState()``, which runs strictly serialized,
/// verifies each item's position before touching it, uses the same move
/// machinery as the Menu Bar Layout pane, catches every error per item,
/// and retries once. A failed move is logged and retried on the next
/// trigger; nothing is ever thrown past this type.
@MainActor
final class AutomationManager: ObservableObject {
    /// Monitor for the system state used by rules.
    let systemMonitor = SystemStateMonitor()

    /// The shared app state.
    private(set) weak var appState: AppState?

    /// Remembered placements, keyed by ``MenuBarItemTag/automationKey``.
    private var placements: [String: String] = [:]

    /// Tags seen in the previous item cache snapshot, used to detect
    /// newly appearing items.
    private var knownTags: Set<MenuBarItemTag> = []

    /// Restores waiting to be executed, keyed by automation key.
    private var pendingRestores: [String: MenuBarSection.Name] = [:]

    /// Return anchors for rule-governed items, keyed by automation key.
    ///
    /// When a rule shows an item, the item's neighbor in the hidden
    /// section is recorded here (value format: `"L|<key>"` to place the
    /// item left of the anchor, `"R|<key>"` for right). When the rule
    /// hides the item again, it returns to its previous spot next to
    /// that neighbor instead of being appended to the end of the
    /// section.
    private var returnAnchors: [String: String] = [:]

    /// Whether the first item cache snapshot has been processed.
    private var hasProcessedInitialSnapshot = false

    /// Whether ``enforceDesiredState()`` is currently running.
    private var isEnforcing = false

    /// Whether another enforcement pass was requested while one was
    /// already running.
    private var needsAnotherPass = false

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    private let logger = Logger(category: "AutomationManager")

    /// Performs the initial setup of the manager.
    func performSetup(with appState: AppState) {
        self.appState = appState

        if let stored = Defaults.dictionary(forKey: .automationRememberedPlacements) as? [String: String] {
            placements = stored
        }
        if let stored = Defaults.dictionary(forKey: .automationReturnAnchors) as? [String: String] {
            returnAnchors = stored
        }

        systemMonitor.start()
        configureCancellables()
    }

    private func configureCancellables() {
        guard let appState else {
            return
        }

        var c = Set<AnyCancellable>()

        // Item cache updates drive placement recording and restoration.
        appState.itemManager.$itemCache
            .removeDuplicates()
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] cache in
                self?.handleItemCacheUpdate(cache)
            }
            .store(in: &c)

        // Condition changes drive the rules.
        Publishers.CombineLatest(
            systemMonitor.$isWiFiConnected.removeDuplicates(),
            systemMonitor.$isOnExternalPower.removeDuplicates()
        )
        .dropFirst()
        .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
        .sink { [weak self] _, _ in
            self?.requestEnforcement(reason: "system condition changed")
        }
        .store(in: &c)

        // Rule configuration changes apply immediately, so the user
        // sees the effect of their settings.
        Publishers.CombineLatest(
            appState.settings.automation.$wifiRule.removeDuplicates(),
            appState.settings.automation.$powerRule.removeDuplicates()
        )
        .dropFirst()
        .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
        .sink { [weak self] _, _ in
            self?.requestEnforcement(reason: "rule configuration changed")
        }
        .store(in: &c)

        cancellables = c
    }

    // MARK: Section Name Persistence

    private func string(from section: MenuBarSection.Name) -> String {
        switch section {
        case .visible: "visible"
        case .hidden: "hidden"
        case .alwaysHidden: "alwaysHidden"
        }
    }

    private func sectionName(from string: String) -> MenuBarSection.Name? {
        switch string {
        case "visible": .visible
        case "hidden": .hidden
        case "alwaysHidden": .alwaysHidden
        default: nil
        }
    }

    // MARK: Item Cache Handling

    private func handleItemCacheUpdate(_ cache: MenuBarItemManager.ItemCache) {
        guard let appState else {
            return
        }

        let settings = appState.settings.automation

        // Snapshot the current placement of every rememberable item.
        var currentPlacements: [String: MenuBarSection.Name] = [:]
        var currentTags = Set<MenuBarItemTag>()
        for section in MenuBarSection.Name.allCases {
            for item in cache.managedItems(for: section) {
                currentTags.insert(item.tag)
                guard
                    item.isMovable,
                    item.canBeHidden,
                    let key = item.tag.automationKey
                else {
                    continue
                }
                currentPlacements[key] = section
            }
        }

        let isInitialSnapshot = !hasProcessedInitialSnapshot
        hasProcessedInitialSnapshot = true

        let appearedTags = currentTags.subtracting(knownTags)
        knownTags = currentTags

        // Items governed by an enabled rule are positioned by the rule,
        // not by the placement memory.
        let ruleGovernedKeys = enabledRuleKeys(settings: settings)

        // Run the rules when the first cache snapshot arrives (the
        // condition publishers may have fired before any items were
        // known, in which case that pass found nothing to move), and
        // when a rule-governed item (re)appears.
        let appearedKeys = Set(appearedTags.compactMap { $0.automationKey })
        if isInitialSnapshot {
            if !ruleGovernedKeys.isEmpty {
                requestEnforcement(reason: "initial rule enforcement")
            }
        } else if !appearedKeys.isDisjoint(with: ruleGovernedKeys) {
            requestEnforcement(reason: "rule-governed item appeared")
        }

        guard settings.rememberItemPositions else {
            return
        }

        // Determine which items need to be moved back to their
        // remembered section. On the initial snapshot, every item is
        // checked (covers items that moved while Ice wasn't running,
        // e.g. across a reboot). Afterwards, only newly appearing items
        // are checked so we never fight the user's own drags.
        var restoreKeys = Set<String>()
        let candidateKeys: Set<String> = if isInitialSnapshot {
            Set(currentPlacements.keys)
        } else {
            appearedKeys
        }

        for key in candidateKeys {
            guard
                !ruleGovernedKeys.contains(key),
                let remembered = placements[key].flatMap(sectionName(from:)),
                let current = currentPlacements[key],
                remembered != current
            else {
                continue
            }
            restoreKeys.insert(key)
            pendingRestores[key] = remembered
        }

        // Record the current placements as the new desired state,
        // except for items we are about to restore (their observed
        // position is the misplaced one) and while Ice itself is
        // moving items around.
        let recentlyMoved = appState.itemManager.lastMoveOperationOccurred(within: .seconds(5))
        if !isEnforcing && !recentlyMoved {
            var changed = false
            for (key, section) in currentPlacements where !restoreKeys.contains(key) && pendingRestores[key] == nil {
                let value = string(from: section)
                if placements[key] != value {
                    placements[key] = value
                    changed = true
                }
            }
            if changed {
                savePlacements()
            }
        }

        if !pendingRestores.isEmpty {
            requestEnforcement(reason: isInitialSnapshot ? "initial placement restore" : "new item appeared misplaced")
        }
    }

    private func savePlacements() {
        Defaults.set(placements, forKey: .automationRememberedPlacements)
    }

    // MARK: Rules

    /// Returns the automation keys of all items governed by an enabled rule.
    private func enabledRuleKeys(settings: AutomationSettings) -> Set<String> {
        var keys = Set<String>()
        if settings.wifiRule.isEnabled {
            keys.formUnion(settings.wifiRule.itemKeys)
        }
        if settings.powerRule.isEnabled {
            keys.formUnion(settings.powerRule.itemKeys)
        }
        return keys
    }

    /// Computes the sections that the enabled rules currently want
    /// their items to be in. Rules whose condition is still unknown
    /// are skipped. If both rules govern the same item, the power rule
    /// takes precedence.
    private func desiredRulePlacements(settings: AutomationSettings) -> [String: MenuBarSection.Name] {
        var desired = [String: MenuBarSection.Name]()

        func apply(rule: AutomationRule, conditionMet: Bool?) {
            guard rule.isEnabled, let conditionMet else {
                return
            }
            let shouldShow = switch rule.action {
            case .showWhenMet: conditionMet
            case .hideWhenMet: !conditionMet
            }
            for key in rule.itemKeys {
                desired[key] = shouldShow ? .visible : .hidden
            }
        }

        apply(rule: settings.wifiRule, conditionMet: systemMonitor.isWiFiConnected)
        apply(rule: settings.powerRule, conditionMet: systemMonitor.isOnExternalPower)

        return desired
    }

    // MARK: Return Anchors

    /// Records the neighbor of the given item in its current section, so
    /// the item can later be returned to the same spot.
    private func recordReturnAnchor(
        for key: String,
        item: MenuBarItem,
        in section: MenuBarSection.Name,
        cache: MenuBarItemManager.ItemCache,
        governedKeys: Set<String>
    ) {
        let sectionItems = cache.managedItems(for: section)
        guard let index = sectionItems.firstIndex(where: { $0.tag == item.tag }) else {
            return
        }

        // Prefer the neighbor to the right, then the one to the left.
        // Skip other rule-governed items; they may be moving too.
        func eligibleAnchorKey(_ candidate: MenuBarItem) -> String? {
            guard
                let anchorKey = candidate.tag.automationKey,
                !governedKeys.contains(anchorKey)
            else {
                return nil
            }
            return anchorKey
        }

        for rightIndex in sectionItems.index(after: index)..<sectionItems.endIndex {
            if let anchorKey = eligibleAnchorKey(sectionItems[rightIndex]) {
                returnAnchors[key] = "L|" + anchorKey
                saveReturnAnchors()
                return
            }
        }
        for leftIndex in stride(from: index - 1, through: sectionItems.startIndex, by: -1) {
            if let anchorKey = eligibleAnchorKey(sectionItems[leftIndex]) {
                returnAnchors[key] = "R|" + anchorKey
                saveReturnAnchors()
                return
            }
        }
    }

    /// Resolves the stored return anchor for the given item into a move
    /// destination, if the anchor is currently in the hidden section.
    private func resolveReturnDestination(
        for key: String,
        items: [MenuBarItem],
        cache: MenuBarItemManager.ItemCache
    ) -> MenuBarItemManager.MoveDestination? {
        guard
            let stored = returnAnchors[key],
            let separatorIndex = stored.firstIndex(of: "|")
        else {
            return nil
        }
        let side = stored[..<separatorIndex]
        let anchorKey = String(stored[stored.index(after: separatorIndex)...])
        guard
            let anchor = items.first(where: { $0.tag.automationKey == anchorKey }),
            cache.address(for: anchor.tag)?.section == .hidden
        else {
            return nil
        }
        return side == "L" ? .leftOfItem(anchor) : .rightOfItem(anchor)
    }

    private func saveReturnAnchors() {
        Defaults.set(returnAnchors, forKey: .automationReturnAnchors)
    }

    // MARK: Enforcement

    /// Requests an enforcement pass. Passes are strictly serialized;
    /// if one is already running, another is queued to run after it.
    private func requestEnforcement(reason: String) {
        logger.info("Enforcement requested: \(reason, privacy: .public)")
        if isEnforcing {
            needsAnotherPass = true
            return
        }
        Task {
            await enforceDesiredState()
        }
    }

    /// Moves items so that the menu bar matches the desired state
    /// (pending restores plus rule placements).
    private func enforceDesiredState() async {
        guard let appState, !isEnforcing else {
            return
        }

        isEnforcing = true
        defer {
            isEnforcing = false
            if needsAnotherPass {
                needsAnotherPass = false
                requestEnforcement(reason: "queued pass")
            }
        }

        // Let the menu bar settle before touching anything. Newly
        // launched apps may still be adjusting their own items.
        try? await Task.sleep(for: .seconds(3))

        let settings = appState.settings.automation

        // Merge desired placements. Rule placements win over restores.
        var desired = pendingRestores
        pendingRestores.removeAll()
        for (key, section) in desiredRulePlacements(settings: settings) {
            desired[key] = section
        }

        guard !desired.isEmpty else {
            return
        }

        var failedMoves = 0
        var performedMoves = 0

        for attempt in 1...2 {
            failedMoves = 0

            // Fetch a fresh list of items each attempt so positions
            // and windows are current.
            let items = await MenuBarItem.getMenuBarItems(option: .activeSpace)

            guard let hiddenControlItem = items.first(matching: .hiddenControlItem) else {
                logger.warning("Hidden control item not found, cannot enforce placements")
                return
            }
            let alwaysHiddenControlItem = items.first(matching: .alwaysHiddenControlItem)

            for (key, targetSection) in desired {
                guard let item = items.first(where: { $0.tag.automationKey == key }) else {
                    // The item isn't in the menu bar right now. Not an
                    // error; it may simply not be running.
                    continue
                }
                guard item.isMovable, item.canBeHidden else {
                    continue
                }

                // Verify against the authoritative cache before moving.
                let cache = appState.itemManager.itemCache
                let currentSection = cache.address(for: item.tag)?.section
                guard currentSection != targetSection else {
                    desired.removeValue(forKey: key)
                    continue
                }

                // Before showing an item, remember which neighbor it sat
                // next to so it can return to the same spot later.
                if targetSection == .visible, let currentSection {
                    recordReturnAnchor(for: key, item: item, in: currentSection, cache: cache, governedKeys: enabledRuleKeys(settings: settings))
                }

                let destination: MenuBarItemManager.MoveDestination = switch targetSection {
                case .visible:
                    .rightOfItem(hiddenControlItem)
                case .hidden:
                    resolveReturnDestination(for: key, items: items, cache: cache) ?? .leftOfItem(hiddenControlItem)
                case .alwaysHidden:
                    // Fall back to the hidden section if the
                    // always-hidden section is disabled.
                    .leftOfItem(alwaysHiddenControlItem ?? hiddenControlItem)
                }

                do {
                    try await appState.itemManager.move(item: item, to: destination)
                    performedMoves += 1
                    desired.removeValue(forKey: key)
                    logger.info(
                        """
                        Moved \(item.logString, privacy: .public) to \
                        \(targetSection.logString, privacy: .public)
                        """
                    )
                } catch {
                    failedMoves += 1
                    logger.error(
                        """
                        Failed to move \(item.logString, privacy: .public) to \
                        \(targetSection.logString, privacy: .public): \
                        \(error, privacy: .public)
                        """
                    )
                }

                // Space out consecutive moves to keep the menu bar
                // (and other apps) from being overwhelmed.
                try? await Task.sleep(for: .milliseconds(500))
            }

            if failedMoves == 0 {
                break
            }
            if attempt == 1 {
                logger.info("Retrying \(failedMoves, privacy: .public) failed move(s)")
                try? await Task.sleep(for: .seconds(5))
            }
        }

        if performedMoves > 0 || failedMoves > 0 {
            logger.info(
                """
                Enforcement finished: \(performedMoves, privacy: .public) moved, \
                \(failedMoves, privacy: .public) failed
                """
            )
        }
    }
}
