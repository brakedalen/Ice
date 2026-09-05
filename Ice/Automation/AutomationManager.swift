//
//  AutomationManager.swift
//  Ice
//

import Combine
import CoreGraphics
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
    private struct ObservedItem {
        let item: MenuBarItem
        let section: MenuBarSection.Name
    }

    private struct DiagnosticItemState: Equatable {
        let key: String
        let section: MenuBarSection.Name
        let sourcePID: pid_t?
        let ownerPID: pid_t
        let isOnScreen: Bool
    }

    /// Monitor for the system state used by rules.
    let systemMonitor = SystemStateMonitor()

    /// The shared app state.
    private(set) weak var appState: AppState?

    /// Remembered placements, keyed by ``MenuBarItemTag/automationKey``.
    private var placements: [String: String] = [:]

    /// Sections for the live item windows seen in the previous cache
    /// snapshot, grouped by automation key.
    ///
    /// Window identifiers are intentionally used here instead of tags. Apps
    /// such as OneDrive can create several status items with the same bundle
    /// identifier and title, and recreate those windows without changing the
    /// resulting tag.
    private var knownInstanceSections = [String: [CGWindowID: MenuBarSection.Name]]()

    /// Last meaningful per-window state written to the diagnostic log. Bounds
    /// are deliberately excluded because hidden windows drift by a few pixels
    /// and would otherwise generate a full log snapshot every five seconds.
    private var diagnosticItemStates = [CGWindowID: DiagnosticItemState]()

    /// Restores waiting to be executed, keyed by automation key.
    private var pendingRestores: [String: MenuBarSection.Name] = [:]

    /// Pending restores created by placement memory rather than rule cleanup.
    /// These are cancelled immediately when placement memory is disabled.
    private var placementMemoryRestoreKeys = Set<String>()

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

    /// Whether cache handling or enforcement was deliberately deferred while
    /// the layout editor temporarily exposed every real menu bar section.
    private var isDeferredForLayoutEditorMove = false

    /// Consecutive enforcement passes that ended with failures. Used to
    /// bound the retry backoff; reset on success and on new triggers.
    private var consecutiveFailedPasses = 0

    /// Keys owned by the previous rule configuration. Used to return items
    /// safely when a rule is disabled or an item is removed from a rule.
    private var previousRuleGovernedKeys = Set<String>()

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    private let logger = Logger(category: "AutomationManager")
    private let diagnosticLogger = AutomationDiagnosticLogger.shared

    /// Performs the initial setup of the manager.
    func performSetup(with appState: AppState) {
        self.appState = appState

        if let stored = Defaults.dictionary(forKey: .automationRememberedPlacements) as? [String: String] {
            placements = stored
        }
        if let stored = Defaults.dictionary(forKey: .automationReturnAnchors) as? [String: String] {
            returnAnchors = stored
        }

        repairInvalidStoredState()

        let version = Bundle.main.versionString ?? "unknown"
        let build = Bundle.main.buildString ?? "unknown"
        logInfo(
            "SESSION_START version=\(version) build=\(build) placements=\(placements.count) " +
            "anchors=\(returnAnchors.count) log=\(diagnosticLogger.logURL.path)"
        )

        systemMonitor.start()
        previousRuleGovernedKeys = enabledRuleKeys(settings: appState.settings.automation)
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
        .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
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
        .sink { [weak self] wifiRule, powerRule in
            self?.handleRuleConfigurationChange(wifiRule: wifiRule, powerRule: powerRule)
        }
        .store(in: &c)

        appState.settings.automation.$rememberItemPositions
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isEnabled in
                self?.handlePlacementMemoryChange(isEnabled: isEnabled)
            }
            .store(in: &c)

        cancellables = c
    }

    // MARK: Diagnostics

    private func logInfo(_ message: String) {
        logger.info("\(message, privacy: .public)")
        diagnosticLogger.write(message)
    }

    private func logWarning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        diagnosticLogger.write(message, level: .warning)
    }

    private func logError(_ message: String) {
        logger.error("\(message, privacy: .public)")
        diagnosticLogger.write(message, level: .error)
    }

    private func diagnosticKey(_ key: String) -> String {
        key.replacingOccurrences(of: "\u{1F}", with: "|")
    }

    private func diagnosticSection(_ section: MenuBarSection.Name?) -> String {
        section.map(string(from:)) ?? "unknown"
    }

    private func anchorKey(from storedAnchor: String) -> String? {
        guard let separatorIndex = storedAnchor.firstIndex(of: "|") else {
            return nil
        }
        return String(storedAnchor[storedAnchor.index(after: separatorIndex)...])
    }

    /// Removes state that could only have been produced by an identity
    /// collision. In particular, an item cannot use itself as its own return
    /// anchor. The associated learned placement is also removed so the user
    /// can teach Ice the intended group position again.
    private func repairInvalidStoredState() {
        let invalidKeys = returnAnchors.compactMap { key, storedAnchor in
            anchorKey(from: storedAnchor) == key ? key : nil
        }
        guard !invalidKeys.isEmpty else {
            return
        }

        for key in invalidKeys {
            returnAnchors.removeValue(forKey: key)
            placements.removeValue(forKey: key)
            logWarning("STATE_REPAIR removed self-referencing anchor key=\(diagnosticKey(key))")
        }
        saveReturnAnchors()
        savePlacements()
    }

    private func handlePlacementMemoryChange(isEnabled: Bool) {
        guard let appState else {
            return
        }

        if !isEnabled {
            let cancelledKeys = placementMemoryRestoreKeys
            for key in cancelledKeys {
                pendingRestores.removeValue(forKey: key)
            }
            placementMemoryRestoreKeys.removeAll()
            logInfo(
                "PLACEMENT_MEMORY disabled cancelled=\(cancelledKeys.map { diagnosticKey($0) }.sorted())"
            )
            return
        }

        logInfo("PLACEMENT_MEMORY enabled action=full-evaluation")
        // Evaluate the published cache immediately. A normal cache refresh may
        // not publish when the window list is unchanged, which previously made
        // enabling this setting appear to do nothing until an app restarted.
        handleItemCacheUpdate(appState.itemManager.itemCache, forceFullEvaluation: true)
        Task {
            await appState.itemManager.cacheItemsRegardless()
            self.handleItemCacheUpdate(appState.itemManager.itemCache, forceFullEvaluation: true)
        }
    }

    private func handleRuleConfigurationChange(
        wifiRule: AutomationRule,
        powerRule: AutomationRule
    ) {
        let currentKeys = AutomationDecisionEngine.governedKeys(
            wifiRule: wifiRule,
            powerRule: powerRule
        )
        let retiredKeys = AutomationDecisionEngine.retiredKeys(
            previous: previousRuleGovernedKeys,
            current: currentKeys
        )

        for key in currentKeys where pendingRestores[key] != nil {
            pendingRestores.removeValue(forKey: key)
            placementMemoryRestoreKeys.remove(key)
            logInfo("RESTORE_CANCELLED key=\(diagnosticKey(key)) reason=rule-reenabled")
        }

        for key in retiredKeys {
            let target = AutomationDecisionEngine.retirementTarget(
                for: key,
                rememberedPlacements: placements
            )
            pendingRestores[key] = target
            placementMemoryRestoreKeys.remove(key)
            logInfo(
                "RULE_RELEASE key=\(diagnosticKey(key)) target=\(diagnosticSection(target))"
            )
        }

        previousRuleGovernedKeys = currentKeys
        requestEnforcement(reason: retiredKeys.isEmpty ? "rule configuration changed" : "rule released item")
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

    private func handleItemCacheUpdate(
        _ cache: MenuBarItemManager.ItemCache,
        forceFullEvaluation: Bool = false
    ) {
        guard let appState else {
            return
        }
        guard !appState.itemManager.isLayoutEditorMoveActive else {
            deferForActiveLayoutEditorMove(phase: "cache-update")
            return
        }

        let settings = appState.settings.automation

        // Snapshot every live item instance. A single automation key may map
        // to multiple windows (for example, one OneDrive icon per account).
        var currentGroups = [String: [ObservedItem]]()
        for section in MenuBarSection.Name.allCases {
            for item in cache.managedItems(for: section) {
                guard
                    item.isMovable,
                    item.canBeHidden,
                    let key = item.tag.automationKey
                else {
                    continue
                }
                currentGroups[key, default: []].append(ObservedItem(item: item, section: section))
            }
        }
        let temporarilyShownKeys = Set(currentGroups.keys.filter {
            appState.itemManager.isTemporarilyShowingItem(withAutomationKey: $0)
        })

        let currentInstanceSections = currentGroups.mapValues { group in
            group.reduce(into: [CGWindowID: MenuBarSection.Name]()) { result, observation in
                result[observation.item.windowID] = observation.section
            }
        }
        let previousInstanceSections = knownInstanceSections

        let isInitialSnapshot = !hasProcessedInitialSnapshot
        hasProcessedInitialSnapshot = true

        let appearedKeys = Set(currentInstanceSections.compactMap { key, instances in
            let previousWindowIDs = Set(previousInstanceSections[key]?.keys.map { $0 } ?? [])
            let currentWindowIDs = Set(instances.keys)
            return currentWindowIDs.subtracting(previousWindowIDs).isEmpty ? nil : key
        })

        logSnapshot(currentGroups, isInitial: isInitialSnapshot, appearedKeys: appearedKeys)

        // Items governed by an enabled rule are positioned by the rule,
        // not by the placement memory.
        let ruleGovernedKeys = enabledRuleKeys(settings: settings)
        for key in ruleGovernedKeys where pendingRestores.removeValue(forKey: key) != nil {
            placementMemoryRestoreKeys.remove(key)
            logInfo("RESTORE_CANCELLED key=\(diagnosticKey(key)) reason=rule-governed")
        }

        // Run the rules when the first cache snapshot arrives (the
        // condition publishers may have fired before any items were
        // known, in which case that pass found nothing to move), and
        // when a rule-governed item (re)appears.
        if isInitialSnapshot {
            if !ruleGovernedKeys.isEmpty {
                requestEnforcement(reason: "initial rule enforcement")
            }
        } else if !appearedKeys.isDisjoint(with: ruleGovernedKeys) {
            requestEnforcement(reason: "rule-governed item appeared")
        }

        knownInstanceSections = currentInstanceSections

        guard settings.rememberItemPositions else {
            // Rule cleanup is independent from placement memory. A released
            // rule can target an item that was not running when the setting
            // changed, so enforce the pending return as soon as it appears.
            let hasRunnableRuleCleanup = pendingRestores.keys.contains {
                currentGroups[$0] != nil &&
                !placementMemoryRestoreKeys.contains($0) &&
                !temporarilyShownKeys.contains($0)
            }
            if hasRunnableRuleCleanup {
                requestEnforcement(reason: "released rule item appeared")
            }
            if isInitialSnapshot {
                logInfo("PLACEMENT_MEMORY disabled")
            }
            return
        }

        // Determine which groups need to be restored. On the initial
        // snapshot, every group is checked. Afterwards, a group is checked
        // when it gains a new window identifier, even if its tag is unchanged.
        var restoreKeys = Set<String>()
        let candidateKeys: Set<String> = if isInitialSnapshot || forceFullEvaluation {
            Set(currentGroups.keys).union(pendingRestores.keys)
        } else {
            appearedKeys.union(pendingRestores.keys)
        }

        for key in candidateKeys {
            guard
                !ruleGovernedKeys.contains(key),
                let group = currentGroups[key],
                !group.isEmpty,
                let remembered = pendingRestores[key] ?? placements[key].flatMap(sectionName(from:))
            else {
                continue
            }

            let mismatchedWindowIDs = group.compactMap { observation in
                observation.section == remembered ? nil : observation.item.windowID
            }
            if mismatchedWindowIDs.isEmpty {
                if pendingRestores.removeValue(forKey: key) != nil {
                    placementMemoryRestoreKeys.remove(key)
                    logInfo(
                        "RESTORE_CONFIRMED key=\(diagnosticKey(key)) " +
                        "section=\(diagnosticSection(remembered)) instances=\(group.count)"
                    )
                }
                continue
            }

            restoreKeys.insert(key)
            let wasAlreadyPending = pendingRestores[key] != nil
            pendingRestores[key] = remembered
            placementMemoryRestoreKeys.insert(key)
            if temporarilyShownKeys.contains(key) {
                if !wasAlreadyPending {
                    logInfo(
                        "RESTORE_DEFERRED key=\(diagnosticKey(key)) target=\(diagnosticSection(remembered)) " +
                        "reason=temporary-show mismatchedWindows=\(mismatchedWindowIDs.sorted())"
                    )
                }
                continue
            }
            logInfo(
                "RESTORE_PENDING key=\(diagnosticKey(key)) target=\(diagnosticSection(remembered)) " +
                "mismatchedWindows=\(mismatchedWindowIDs.sorted())"
            )
        }

        let recentlyMoved = appState.itemManager.lastMoveOperationOccurred(within: .seconds(5))
        var placementsChanged = false

        // If the user moves one member of a duplicate group, treat its new
        // section as the desired section for the whole group. This gives a
        // deterministic fallback when the app exposes no account-specific
        // identity, while still allowing one drag to teach Ice the placement.
        if !isEnforcing && !recentlyMoved {
            for (key, group) in currentGroups {
                let currentSections = Set(group.map(\.section))
                guard
                    group.count > 1,
                    currentSections.count > 1,
                    !appearedKeys.contains(key),
                    !ruleGovernedKeys.contains(key),
                    !temporarilyShownKeys.contains(key),
                    pendingRestores[key] == nil
                else {
                    continue
                }

                let previousSections = previousInstanceSections[key] ?? [:]
                let changedTargets = Set(group.compactMap { observation -> MenuBarSection.Name? in
                    guard
                        let previous = previousSections[observation.item.windowID],
                        previous != observation.section
                    else {
                        return nil
                    }
                    return observation.section
                })

                guard changedTargets.count == 1, let target = changedTargets.first else {
                    logWarning(
                        "GROUP_AMBIGUOUS key=\(diagnosticKey(key)) " +
                        "sections=\(currentSections.map { string(from: $0) }.sorted())"
                    )
                    continue
                }

                placements[key] = string(from: target)
                pendingRestores[key] = target
                placementMemoryRestoreKeys.insert(key)
                restoreKeys.insert(key)
                placementsChanged = true
                logInfo(
                    "GROUP_TARGET_LEARNED key=\(diagnosticKey(key)) " +
                    "target=\(diagnosticSection(target)) instances=\(group.count)"
                )
            }

            // Record groups that currently agree on one section. Never let
            // one member of an ambiguous group overwrite the group's target.
            for (key, group) in currentGroups {
                guard
                    !ruleGovernedKeys.contains(key),
                    !temporarilyShownKeys.contains(key),
                    !restoreKeys.contains(key),
                    pendingRestores[key] == nil
                else {
                    continue
                }
                let currentSections = Set(group.map(\.section))
                guard currentSections.count == 1, let section = currentSections.first else {
                    continue
                }
                let value = string(from: section)
                if placements[key] != value {
                    placements[key] = value
                    placementsChanged = true
                    logInfo(
                        "PLACEMENT_LEARNED key=\(diagnosticKey(key)) " +
                        "section=\(diagnosticSection(section)) instances=\(group.count)"
                    )
                }
            }
        }

        if placementsChanged {
            savePlacements()
        }

        let hasRunnableRestore = pendingRestores.keys.contains {
            currentGroups[$0] != nil && !temporarilyShownKeys.contains($0)
        }
        if hasRunnableRestore {
            requestEnforcement(reason: isInitialSnapshot ? "initial placement restore" : "new item appeared misplaced")
        }
    }

    private func logSnapshot(
        _ groups: [String: [ObservedItem]],
        isInitial: Bool,
        appearedKeys: Set<String>
    ) {
        var currentStates = [CGWindowID: DiagnosticItemState]()
        for (key, group) in groups {
            for observation in group {
                let item = observation.item
                currentStates[item.windowID] = DiagnosticItemState(
                    key: key,
                    section: observation.section,
                    sourcePID: item.sourcePID,
                    ownerPID: item.ownerPID,
                    isOnScreen: item.isOnScreen
                )
            }
        }

        let changedWindowIDs = Set(currentStates.compactMap { windowID, state in
            diagnosticItemStates[windowID] == state ? nil : windowID
        })
        let removedWindowIDs = Set(diagnosticItemStates.keys).subtracting(currentStates.keys)

        guard isInitial || !changedWindowIDs.isEmpty || !removedWindowIDs.isEmpty else {
            return
        }

        let instanceCount = groups.values.reduce(0) { $0 + $1.count }
        logInfo(
            "SNAPSHOT initial=\(isInitial) groups=\(groups.count) instances=\(instanceCount) " +
            "appeared=\(appearedKeys.map { diagnosticKey($0) }.sorted()) " +
            "changedWindows=\(changedWindowIDs.sorted()) removedWindows=\(removedWindowIDs.sorted())"
        )

        for key in groups.keys.sorted() {
            guard let group = groups[key] else {
                continue
            }
            let windowIDs = Set(group.map(\.item.windowID))
            let previousWindowIDs = Set(diagnosticItemStates.compactMap { windowID, state in
                state.key == key ? windowID : nil
            })
            if group.count > 1, isInitial || windowIDs != previousWindowIDs {
                let windowIDs = group.map(\.item.windowID).sorted()
                logWarning(
                    "DUPLICATE_GROUP key=\(diagnosticKey(key)) count=\(group.count) windows=\(windowIDs)"
                )
            }
            for observation in group
                .filter({ isInitial || changedWindowIDs.contains($0.item.windowID) })
                .sorted(by: { $0.item.windowID < $1.item.windowID }) {
                let item = observation.item
                let sourcePID = item.sourcePID.map(String.init) ?? "nil"
                let minX = String(format: "%.1f", item.bounds.minX)
                let width = String(format: "%.1f", item.bounds.width)
                logInfo(
                    "ITEM key=\(diagnosticKey(key)) section=\(diagnosticSection(observation.section)) " +
                    "windowID=\(item.windowID) sourcePID=\(sourcePID) ownerPID=\(item.ownerPID) " +
                    "onScreen=\(item.isOnScreen) x=\(minX) width=\(width)"
                )
            }
        }

        for windowID in removedWindowIDs.sorted() {
            guard let previous = diagnosticItemStates[windowID] else {
                continue
            }
            logInfo(
                "ITEM_REMOVED key=\(diagnosticKey(previous.key)) windowID=\(windowID) " +
                "sourcePID=\(previous.sourcePID.map(String.init) ?? "nil")"
            )
        }

        diagnosticItemStates = currentStates
    }

    private func savePlacements() {
        Defaults.set(placements, forKey: .automationRememberedPlacements)
    }

    // MARK: Rules

    /// Returns the automation keys of all items governed by an enabled rule.
    private func enabledRuleKeys(settings: AutomationSettings) -> Set<String> {
        AutomationDecisionEngine.governedKeys(
            wifiRule: settings.wifiRule,
            powerRule: settings.powerRule
        )
    }

    /// Computes the sections that the enabled rules currently want
    /// their items to be in. Rules whose condition is still unknown
    /// are skipped. If both rules govern the same item, the power rule
    /// takes precedence.
    private func desiredRulePlacements(settings: AutomationSettings) -> [String: MenuBarSection.Name] {
        AutomationDecisionEngine.desiredPlacements(
            wifiRule: settings.wifiRule,
            powerRule: settings.powerRule,
            isWiFiConnected: systemMonitor.isWiFiConnected,
            isOnExternalPower: systemMonitor.isOnExternalPower
        )
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
        guard let index = sectionItems.firstIndex(where: { $0.windowID == item.windowID }) else {
            return
        }

        // Prefer the neighbor to the right, then the one to the left.
        // Skip other instances of the same group and rule-governed items;
        // either may be moving at the same time.
        func eligibleAnchorKey(_ candidate: MenuBarItem) -> String? {
            guard
                let anchorKey = candidate.tag.automationKey,
                anchorKey != key,
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
                logInfo(
                    "ANCHOR_SAVED key=\(diagnosticKey(key)) side=left " +
                    "anchor=\(diagnosticKey(anchorKey))"
                )
                return
            }
        }
        for leftIndex in stride(from: index - 1, through: sectionItems.startIndex, by: -1) {
            if let anchorKey = eligibleAnchorKey(sectionItems[leftIndex]) {
                returnAnchors[key] = "R|" + anchorKey
                saveReturnAnchors()
                logInfo(
                    "ANCHOR_SAVED key=\(diagnosticKey(key)) side=right " +
                    "anchor=\(diagnosticKey(anchorKey))"
                )
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
        guard let stored = returnAnchors[key], let anchorKey = anchorKey(from: stored), anchorKey != key else {
            return nil
        }
        let side = stored.prefix { $0 != "|" }
        guard
            let anchor = items.first(where: { $0.tag.automationKey == anchorKey }),
            cache.address(forWindowID: anchor.windowID)?.section == .hidden
        else {
            return nil
        }
        return side == "L" ? .leftOfItem(anchor) : .rightOfItem(anchor)
    }

    private func saveReturnAnchors() {
        Defaults.set(returnAnchors, forKey: .automationReturnAnchors)
    }

    // MARK: Enforcement

    /// Marks automation work as deferred while the layout editor temporarily
    /// changes every section boundary. Those intermediate sections are not
    /// user state and must never be learned or enforced.
    private func deferForActiveLayoutEditorMove(phase: String) {
        guard let appState else {
            return
        }
        let wasAlreadyDeferred = isDeferredForLayoutEditorMove
        isDeferredForLayoutEditorMove = true
        if !wasAlreadyDeferred {
            logInfo(
                "AUTOMATION_LAYOUT_DEFERRED phase=\(phase) " +
                "generation=\(appState.itemManager.layoutEditorMoveGeneration)"
            )
        }
    }

    /// Returns whether an enforcement pass must stop because the layout it
    /// inspected is no longer current.
    private func layoutChangedDuringEnforcement(
        expectedGeneration: UInt64,
        phase: String
    ) -> Bool {
        guard let appState else {
            return true
        }
        let itemManager = appState.itemManager
        if itemManager.isLayoutEditorMoveActive {
            deferForActiveLayoutEditorMove(phase: phase)
            return true
        }
        guard itemManager.layoutEditorMoveGeneration == expectedGeneration else {
            needsAnotherPass = true
            logInfo(
                "AUTOMATION_LAYOUT_STALE phase=\(phase) expectedGeneration=\(expectedGeneration) " +
                "actualGeneration=\(itemManager.layoutEditorMoveGeneration)"
            )
            return true
        }
        return false
    }

    /// Requests an enforcement pass. Passes are strictly serialized;
    /// if one is already running, another is queued to run after it.
    private func requestEnforcement(reason: String) {
        if appState?.itemManager.isLayoutEditorMoveActive == true {
            deferForActiveLayoutEditorMove(phase: "request-\(reason)")
            return
        }
        let requestID = UUID()
        let requestedAt = ProcessInfo.processInfo.systemUptime
        logInfo(
            "ENFORCEMENT_REQUEST id=\(requestID) reason=\(reason) pending=\(pendingRestores.count) " +
            "running=\(isEnforcing)"
        )
        if reason != "retry after failure" {
            consecutiveFailedPasses = 0
        }
        if isEnforcing {
            needsAnotherPass = true
            return
        }
        Task {
            await enforceDesiredState(requestID: requestID, requestedAt: requestedAt)
        }
    }

    /// Re-evaluates automation only after the layout editor has restored the
    /// real section dividers. The enforcement pass refreshes the cache before
    /// making any move decision.
    func resumeAfterLayoutEditorMove() {
        let wasDeferred = isDeferredForLayoutEditorMove
        isDeferredForLayoutEditorMove = false
        logInfo("AUTOMATION_LAYOUT_RESUMED wasDeferred=\(wasDeferred)")
        requestEnforcement(reason: "layout editor move ended")
    }

    /// Resumes work that was deliberately deferred while Ice temporarily
    /// showed and clicked an item from the Ice Bar or search panel.
    func resumeAfterTemporaryShow(forAutomationKey key: String) {
        guard let appState else {
            return
        }
        let settings = appState.settings.automation
        guard pendingRestores[key] != nil || enabledRuleKeys(settings: settings).contains(key) else {
            return
        }
        logInfo("AUTOMATION_RESUMED key=\(diagnosticKey(key)) reason=temporary-show-ended")
        requestEnforcement(reason: "temporary show ended")
    }

    /// Confirms that one member of a duplicate group remains in its target
    /// section while every window that was present before the move still
    /// exists.
    ///
    /// Some multi-account apps remove and recreate all their status items a
    /// few seconds after consecutive moves. Checking twice gives the app time
    /// to settle before another member of the same group is touched.
    private func confirmStagedMove(
        key: String,
        windowID: CGWindowID,
        targetSection: MenuBarSection.Name,
        expectedWindowIDs: Set<CGWindowID>,
        appState: AppState
    ) async -> Bool {
        let checkpoints: [(name: String, delay: Duration)] = [
            ("initial", .milliseconds(1_250)),
            ("stable", .seconds(5)),
        ]

        for checkpoint in checkpoints {
            try? await Task.sleep(for: checkpoint.delay)
            guard !Task.isCancelled else {
                return false
            }

            await appState.itemManager.cacheItemsRegardless()

            let cache = appState.itemManager.itemCache
            let currentWindowIDs = Set(cache.managedItems.compactMap { item in
                item.tag.automationKey == key ? item.windowID : nil
            })
            let missingWindowIDs = expectedWindowIDs.subtracting(currentWindowIDs)

            guard missingWindowIDs.isEmpty else {
                logWarning(
                    "MOVE_UNCONFIRMED key=\(diagnosticKey(key)) windowID=\(windowID) " +
                    "checkpoint=\(checkpoint.name) reason=group-changed " +
                    "missingWindows=\(missingWindowIDs.sorted())"
                )
                return false
            }

            guard let actualSection = cache.address(forWindowID: windowID)?.section else {
                logWarning(
                    "MOVE_UNCONFIRMED key=\(diagnosticKey(key)) windowID=\(windowID) " +
                    "checkpoint=\(checkpoint.name) reason=item-missing"
                )
                return false
            }

            guard actualSection == targetSection else {
                logWarning(
                    "MOVE_UNCONFIRMED key=\(diagnosticKey(key)) windowID=\(windowID) " +
                    "checkpoint=\(checkpoint.name) reason=wrong-section " +
                    "actual=\(diagnosticSection(actualSection)) " +
                    "expected=\(diagnosticSection(targetSection))"
                )
                return false
            }

            logInfo(
                "MOVE_CHECK key=\(diagnosticKey(key)) windowID=\(windowID) " +
                "checkpoint=\(checkpoint.name) section=\(diagnosticSection(actualSection)) " +
                "instances=\(currentWindowIDs.count)"
            )
        }

        logInfo(
            "MOVE_CONFIRMED key=\(diagnosticKey(key)) windowID=\(windowID) " +
            "target=\(diagnosticSection(targetSection)) stableForSeconds=5"
        )
        return true
    }

    /// Moves items so that the menu bar matches the desired state
    /// (pending restores plus rule placements).
    private func enforceDesiredState(requestID: UUID, requestedAt: TimeInterval) async {
        guard let appState, !isEnforcing else {
            logInfo("ENFORCEMENT_COALESCED id=\(requestID)")
            return
        }

        isEnforcing = true
        let startedAt = ProcessInfo.processInfo.systemUptime
        logInfo("ENFORCEMENT_PHASE id=\(requestID) phase=start queueMs=\(Int((startedAt - requestedAt) * 1_000))")
        let startingLayoutGeneration = appState.itemManager.layoutEditorMoveGeneration
        defer {
            logInfo(
                "ENFORCEMENT_PASS_END id=\(requestID) " +
                "durationMs=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000))"
            )
            isEnforcing = false
            if needsAnotherPass {
                needsAnotherPass = false
                requestEnforcement(reason: "queued pass")
            }
        }

        // Let the menu bar settle before touching anything. Newly
        // launched apps may still be adjusting their own items.
        try? await Task.sleep(for: .milliseconds(1_250))
        logInfo(
            "ENFORCEMENT_PHASE id=\(requestID) phase=settled " +
            "elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000))"
        )

        guard !layoutChangedDuringEnforcement(
            expectedGeneration: startingLayoutGeneration,
            phase: "before-cache-refresh"
        ) else {
            return
        }

        // The request may have been based on a cache published before a user
        // drag. Always refresh after the settle delay so the current section,
        // window identifier, and divider geometry agree.
        let cacheStartedAt = ProcessInfo.processInfo.systemUptime
        await appState.itemManager.cacheItemsRegardless()
        logInfo(
            "ENFORCEMENT_PHASE id=\(requestID) phase=cache-refreshed " +
            "durationMs=\(Int((ProcessInfo.processInfo.systemUptime - cacheStartedAt) * 1_000))"
        )
        guard !layoutChangedDuringEnforcement(
            expectedGeneration: startingLayoutGeneration,
            phase: "after-cache-refresh"
        ) else {
            return
        }

        let settings = appState.settings.automation

        let temporarilyShownKeys = Set(
            pendingRestores.keys.filter {
                appState.itemManager.isTemporarilyShowingItem(withAutomationKey: $0)
            }
        ).union(
            desiredRulePlacements(settings: settings).keys.filter {
                appState.itemManager.isTemporarilyShowingItem(withAutomationKey: $0)
            }
        )

        // Merge desired placements. Rule placements win over restores, while
        // active temporary-show groups are left untouched until their click
        // interaction and rehide operation have finished.
        var desired = pendingRestores.filter { !temporarilyShownKeys.contains($0.key) }
        for (key, section) in desiredRulePlacements(settings: settings) where !temporarilyShownKeys.contains(key) {
            desired[key] = section
        }

        if !temporarilyShownKeys.isEmpty {
            logInfo(
                "ENFORCEMENT_DEFERRED keys=\(temporarilyShownKeys.map { diagnosticKey($0) }.sorted()) " +
                "reason=temporary-show"
            )
        }

        guard !desired.isEmpty else {
            logInfo(
                "ENFORCEMENT_EMPTY wifi=\(String(describing: systemMonitor.isWiFiConnected)) " +
                "power=\(String(describing: systemMonitor.isOnExternalPower))"
            )
            return
        }

        var failedMoves = 0
        var performedMoves = 0

        for attempt in 1...2 {
            failedMoves = 0

            // Fetch a fresh list of items each attempt so positions
            // and windows are current. No list option: offscreen (stashed)
            // items and control items must always be included.
            let items = await MenuBarItem.getMenuBarItems(option: [])

            guard let hiddenControlItem = items.first(matching: .hiddenControlItem) else {
                // The menu bar can be momentarily unreadable (e.g. while
                // the item cache is rebuilding). Never give up: put the
                // work back and retry shortly.
                logWarning("ENFORCEMENT_BLOCKED reason=missing-hidden-control-item")
                scheduleRetry()
                return
            }
            let alwaysHiddenControlItem = items.first(matching: .alwaysHiddenControlItem)

            for key in desired.keys.sorted() {
                guard !layoutChangedDuringEnforcement(
                    expectedGeneration: startingLayoutGeneration,
                    phase: "before-group-\(diagnosticKey(key))"
                ) else {
                    return
                }
                guard let targetSection = desired[key] else {
                    continue
                }
                guard !appState.itemManager.isTemporarilyShowingItem(withAutomationKey: key) else {
                    logInfo("GROUP_DEFERRED key=\(diagnosticKey(key)) reason=temporary-show")
                    continue
                }

                // Restrict the fresh global window list to instances present
                // in the active cache. This avoids treating stale windows from
                // another Space as extra members of the group.
                let cache = appState.itemManager.itemCache
                let cachedWindowIDs = Set(cache.managedItems.compactMap { item in
                    item.tag.automationKey == key ? item.windowID : nil
                })
                let matchingItems = items.filter {
                    cachedWindowIDs.contains($0.windowID) && $0.isMovable && $0.canBeHidden
                }.sorted { $0.windowID < $1.windowID }

                guard !matchingItems.isEmpty else {
                    // The item isn't in the menu bar right now. Not an
                    // error; it may simply not be running.
                    logInfo("GROUP_NOT_RUNNING key=\(diagnosticKey(key))")
                    continue
                }

                let effectiveTarget: MenuBarSection.Name = if targetSection == .alwaysHidden && alwaysHiddenControlItem == nil {
                    .hidden
                } else {
                    targetSection
                }

                logInfo(
                    "GROUP_ENFORCEMENT attempt=\(attempt) key=\(diagnosticKey(key)) " +
                    "target=\(diagnosticSection(targetSection)) effectiveTarget=\(diagnosticSection(effectiveTarget)) " +
                    "instances=\(matchingItems.count)"
                )

                var groupHadMove = false
                var groupHadFailure = false
                var didRecordReturnAnchor = false
                let stagesMoves = matchingItems.count > 1
                let expectedWindowIDs = Set(matchingItems.map(\.windowID))

                for item in matchingItems {
                    // Tags are not unique for multi-account apps. Always use
                    // the live window identifier for cache lookup.
                    guard let currentSection = cache.address(forWindowID: item.windowID)?.section else {
                        failedMoves += 1
                        groupHadFailure = true
                        logWarning(
                            "CACHE_MISS key=\(diagnosticKey(key)) windowID=\(item.windowID) " +
                            "sourcePID=\(item.sourcePID.map(String.init) ?? "nil")"
                        )
                        continue
                    }

                    guard currentSection != effectiveTarget else {
                        logInfo(
                            "INSTANCE_CORRECT key=\(diagnosticKey(key)) windowID=\(item.windowID) " +
                            "section=\(diagnosticSection(currentSection))"
                        )
                        continue
                    }

                    // Before showing a group, remember one stable neighbor in
                    // its current section. Other members of the same group are
                    // explicitly excluded from being the anchor.
                    if effectiveTarget == .visible && !didRecordReturnAnchor {
                        recordReturnAnchor(
                            for: key,
                            item: item,
                            in: currentSection,
                            cache: cache,
                            governedKeys: enabledRuleKeys(settings: settings)
                        )
                        didRecordReturnAnchor = true
                    }

                    let destination: MenuBarItemManager.MoveDestination = switch effectiveTarget {
                    case .visible:
                        .rightOfItem(hiddenControlItem)
                    case .hidden:
                        resolveReturnDestination(for: key, items: items, cache: cache) ?? .leftOfItem(hiddenControlItem)
                    case .alwaysHidden:
                        .leftOfItem(alwaysHiddenControlItem ?? hiddenControlItem)
                    }

                    logInfo(
                        "MOVE_START key=\(diagnosticKey(key)) windowID=\(item.windowID) " +
                        "from=\(diagnosticSection(currentSection)) to=\(diagnosticSection(effectiveTarget))"
                    )
                    guard !layoutChangedDuringEnforcement(
                        expectedGeneration: startingLayoutGeneration,
                        phase: "before-move-\(diagnosticKey(key))"
                    ) else {
                        return
                    }
                    do {
                        try await appState.itemManager.move(
                            item: item,
                            to: destination,
                            origin: .automation
                        )
                        performedMoves += 1
                        groupHadMove = true
                        logInfo(
                            "MOVE_EVENTS_ACCEPTED key=\(diagnosticKey(key)) windowID=\(item.windowID) " +
                            "target=\(diagnosticSection(effectiveTarget))"
                        )

                        if stagesMoves {
                            let confirmed = await confirmStagedMove(
                                key: key,
                                windowID: item.windowID,
                                targetSection: effectiveTarget,
                                expectedWindowIDs: expectedWindowIDs,
                                appState: appState
                            )
                            if confirmed {
                                // Recompute the group from a fresh window list
                                // before touching another duplicate instance.
                                needsAnotherPass = true
                                logInfo(
                                    "GROUP_STAGED key=\(diagnosticKey(key)) " +
                                    "completedWindowID=\(item.windowID) nextPass=true"
                                )
                            } else {
                                failedMoves += 1
                                groupHadFailure = true
                                logWarning(
                                    "GROUP_STAGED_ABORTED key=\(diagnosticKey(key)) " +
                                    "windowID=\(item.windowID)"
                                )
                            }
                            break
                        }
                    } catch {
                        failedMoves += 1
                        groupHadFailure = true
                        logError(
                            "MOVE_FAILURE key=\(diagnosticKey(key)) windowID=\(item.windowID) " +
                            "target=\(diagnosticSection(effectiveTarget)) error=\(String(describing: error))"
                        )
                    }

                    // Duplicate groups leave the loop above and wait for a
                    // cache-confirmed follow-up pass. Space out only ordinary
                    // consecutive moves here.
                    try? await Task.sleep(for: .milliseconds(500))
                }

                if !groupHadFailure && !groupHadMove {
                    // The cache authoritatively confirms every live instance
                    // is in the requested section.
                    if pendingRestores[key] != nil {
                        pendingRestores.removeValue(forKey: key)
                        placementMemoryRestoreKeys.remove(key)
                        logInfo(
                            "RESTORE_CONFIRMED key=\(diagnosticKey(key)) " +
                            "section=\(diagnosticSection(effectiveTarget)) instances=\(matchingItems.count)"
                        )
                    }
                    desired.removeValue(forKey: key)
                } else if !groupHadFailure && pendingRestores[key] == nil {
                    // Rule-driven placements are recomputed from live state and
                    // do not need a persistent confirmation marker.
                    desired.removeValue(forKey: key)
                }
            }

            if failedMoves == 0 {
                break
            }
            if attempt == 1 {
                logInfo("ENFORCEMENT_RETRY failedMoves=\(failedMoves)")
                try? await Task.sleep(for: .seconds(5))
            }
        }

        if performedMoves > 0 {
            // Moving an item changes bounds but not necessarily its window ID,
            // so the normal cache-if-needed path may skip the update. Refresh
            // explicitly once the manager's recent-move guard has elapsed.
            logInfo("CACHE_REFRESH_SCHEDULED moved=\(performedMoves)")
            try? await Task.sleep(for: .milliseconds(1_250))
            await appState.itemManager.cacheItemsRegardless()
        }

        if performedMoves > 0 || failedMoves > 0 {
            logInfo(
                "ENFORCEMENT_FINISHED moved=\(performedMoves) failed=\(failedMoves) " +
                "pending=\(pendingRestores.count)"
            )
        }

        if failedMoves > 0 {
            scheduleRetry()
        } else {
            consecutiveFailedPasses = 0
        }
    }

    /// Schedules a bounded retry of the enforcement pass. The desired
    /// state is recomputed from the live conditions on each pass, so
    /// retrying is always safe.
    private func scheduleRetry() {
        consecutiveFailedPasses += 1
        guard consecutiveFailedPasses <= 6 else {
            logError("RETRY_EXHAUSTED attempts=\(consecutiveFailedPasses - 1)")
            return
        }
        let delay = Duration.seconds(min(5 * consecutiveFailedPasses, 30))
        logInfo("RETRY_SCHEDULED attempt=\(consecutiveFailedPasses) delay=\(delay)")
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            self?.requestEnforcement(reason: "retry after failure")
        }
    }
}
