//
//  MenuBarItemManager.swift
//  Ice
//

import Cocoa
import ApplicationServices
import Combine
import OSLog
import Semaphore

/// Manager for menu bar items.
@MainActor
final class MenuBarItemManager: ObservableObject {
    /// The current cache of menu bar items.
    @Published private(set) var itemCache = ItemCache(displayID: nil)

    /// Logger for the menu bar item manager.
    private nonisolated let logger = Logger.menuBarItemManager

    /// File logger for temporary-show and duplicate-item diagnostics.
    private nonisolated let diagnosticLogger = AutomationDiagnosticLogger.shared

    /// Semaphore to prevent overlapping event operations.
    private nonisolated let eventSemaphore = AsyncSemaphore(value: 1)

    /// Semaphore covering the complete lifecycle of a move, including native
    /// section reveals.
    private nonisolated let moveSemaphore = AsyncSemaphore(value: 1)

    /// Actor for managing menu bar item cache operations.
    private let cacheActor = CacheActor()

    /// Contexts for temporarily shown menu bar items.
    private var temporarilyShownItemContexts = [TemporarilyShownItemContext]()

    /// Contexts currently being returned to their original positions. They
    /// remain visible to cache and automation lookups across async move calls.
    private var rehidingItemContexts = [TemporarilyShownItemContext]()

    /// Prevents overlapping rehide passes while the main actor is suspended
    /// in a menu bar move operation.
    private var isRehidingTemporaryItems = false

    /// A timer for rehiding temporarily shown menu bar items.
    private var rehideTimer: Timer?

    /// State owned by a native section reveal used to activate OneDrive.
    ///
    /// OneDrive anchors its interface to the real status item. Keeping the
    /// section expanded until that interface closes preserves the same AppKit
    /// lifecycle the item has when Ice is not hiding it.
    private var oneDriveNativeRevealContext: OneDriveNativeRevealContext?

    /// Whether Ice has temporarily exposed the real menu bar section so
    /// OneDrive can anchor its interface to the native status item.
    var isOneDriveNativeRevealActive: Bool {
        oneDriveNativeRevealContext != nil
    }

    /// Whether a user-initiated move from the layout editor currently owns
    /// the real menu bar geometry. Automation must not inspect or mutate item
    /// sections while all dividers are temporarily revealed.
    private(set) var isLayoutEditorMoveActive = false

    /// Changes at both ends of every layout-editor move. Long-running
    /// automation passes use this to discard decisions made from an older
    /// menu bar layout, even if the move began and ended during an `await`.
    private(set) var layoutEditorMoveGeneration: UInt64 = 0

    /// Monitors the OneDrive interface associated with the current reveal.
    private var oneDriveNativeRevealMonitor: Task<Void, Never>?

    /// Invalidates older interface monitors when another OneDrive item is
    /// activated before the previous monitor has finished.
    private var oneDriveNativeRevealGeneration = 0

    /// Timestamp of the most recent menu bar item move operation.
    private var lastMoveOperationTimestamp: ContinuousClock.Instant?

    /// Cached timeouts for move operations.
    private var moveOperationTimeouts = [MenuBarItemTag: Duration]()

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// The shared app state.
    private(set) weak var appState: AppState?

    /// Sets up the manager.
    func performSetup(with appState: AppState) async {
        self.appState = appState
        await cacheItemsRegardless()
        configureCancellables(with: appState)
    }

    /// Configures the internal observers for the manager.
    private func configureCancellables(with appState: AppState) {
        var c = Set<AnyCancellable>()

        NSWorkspace.shared.publisher(for: \.runningApplications)
            .delay(for: 0.25, scheduler: DispatchQueue.main)
            .discardMerge(Timer.publish(every: 5, on: .main, in: .default).autoconnect())
            .debounce(for: 1, scheduler: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else {
                    return
                }
                Task {
                    await self.cacheItemsIfNeeded()
                }
            }
            .store(in: &c)

        appState.navigationState.$settingsNavigationIdentifier
            .sink { [weak self] identifier in
                guard let self, identifier == .menuBarLayout else {
                    return
                }
                Task {
                    await self.cacheItemsRegardless()
                }
            }
            .store(in: &c)

        cancellables = c
    }

    /// Returns a Boolean value that indicates whether the most recent
    /// menu bar item move operation occurred within the given duration.
    func lastMoveOperationOccurred(within duration: Duration) -> Bool {
        guard let timestamp = lastMoveOperationTimestamp else {
            return false
        }
        return timestamp.duration(to: .now) <= duration
    }
}

// MARK: - Item Cache

extension MenuBarItemManager {
    /// An actor that manages menu bar item cache operations.
    private final actor CacheActor {
        /// Stored task for the current cache operation.
        private var cacheTask: Task<Void, Never>?

        /// A list of the menu bar item window identifiers at the time
        /// of the previous cache.
        private(set) var cachedItemWindowIDs = [CGWindowID]()

        /// Runs the given async closure as a task and waits for it to
        /// complete before returning.
        ///
        /// If a task from a previous call to this method is currently
        /// running, that task is cancelled and replaced.
        func runCacheTask(_ operation: @escaping () async -> Void) async {
            cacheTask.take()?.cancel()
            let task = Task(operation: operation)
            cacheTask = task
            await task.value
        }

        /// Updates the list of cached menu bar item window identifiers.
        func updateCachedItemWindowIDs(_ itemWindowIDs: [CGWindowID]) {
            cachedItemWindowIDs = itemWindowIDs
        }

        /// Clears the list of cached menu bar item window identifiers.
        func clearCachedItemWindowIDs() {
            cachedItemWindowIDs.removeAll()
        }
    }

    /// Cache for menu bar items.
    struct ItemCache: Hashable {
        /// Storage for cached menu bar items, keyed by section.
        private var storage = [MenuBarSection.Name: [MenuBarItem]]()

        /// The identifier of the display with the active menu bar at
        /// the time this cache was created.
        let displayID: CGDirectDisplayID?

        /// The cached menu bar items as an array.
        var managedItems: [MenuBarItem] {
            MenuBarSection.Name.allCases.reduce(into: []) { result, section in
                guard let items = storage[section] else {
                    return
                }
                result.append(contentsOf: items)
            }
        }

        /// Creates a cache with the given display identifier.
        init(displayID: CGDirectDisplayID?) {
            self.displayID = displayID
        }

        // TODO: This is redundant now, so remove it.
        /// Returns the managed menu bar items for the given section.
        func managedItems(for section: MenuBarSection.Name) -> [MenuBarItem] {
            self[section]
        }

        /// Returns the address for the menu bar item with the given window
        /// identifier, if it exists in the cache.
        ///
        /// Unlike a tag, a window identifier distinguishes multiple live
        /// status items that share the same bundle identifier and title.
        func address(forWindowID windowID: CGWindowID) -> (section: MenuBarSection.Name, index: Int)? {
            for (section, items) in storage {
                guard let index = items.firstIndex(where: { $0.windowID == windowID }) else {
                    continue
                }
                return (section, index)
            }
            return nil
        }

        /// Returns whether this cache has the same UI-relevant layout as
        /// another cache.
        ///
        /// Hidden status item windows can drift by a few pixels while their
        /// identity, section, ordering, and size remain unchanged. Their live
        /// bounds are read again before interaction, so publishing those
        /// origin-only changes would only cause unnecessary SwiftUI updates.
        func hasSamePublishedLayout(as other: ItemCache) -> Bool {
            guard displayID == other.displayID else {
                return false
            }

            for section in MenuBarSection.Name.allCases {
                let items = self[section]
                let otherItems = other[section]
                guard items.count == otherItems.count else {
                    return false
                }

                for (item, otherItem) in zip(items, otherItems) {
                    guard
                        item.tag == otherItem.tag,
                        item.windowID == otherItem.windowID,
                        item.ownerPID == otherItem.ownerPID,
                        item.sourcePID == otherItem.sourcePID,
                        NSStringFromSize(item.bounds.size) == NSStringFromSize(otherItem.bounds.size),
                        item.title == otherItem.title,
                        item.isOnScreen == otherItem.isOnScreen
                    else {
                        return false
                    }
                }
            }

            return true
        }

        /// Inserts the given menu bar item into the cache at the specified
        /// destination.
        mutating func insert(_ item: MenuBarItem, at destination: MoveDestination) {
            let targetTag = destination.targetItem.tag

            if targetTag == .hiddenControlItem {
                switch destination {
                case .leftOfItem:
                    self[.hidden].append(item)
                case .rightOfItem:
                    self[.visible].insert(item, at: 0)
                }
                return
            }

            if targetTag == .alwaysHiddenControlItem {
                switch destination {
                case .leftOfItem:
                    self[.alwaysHidden].append(item)
                case .rightOfItem:
                    self[.hidden].insert(item, at: 0)
                }
                return
            }

            guard case (let section, var index)? = address(forWindowID: destination.targetItem.windowID) else {
                return
            }

            if case .rightOfItem = destination {
                let range = self[section].startIndex...self[section].endIndex
                index = (index + 1).clamped(to: range)
            }

            self[section].insert(item, at: index)
        }

        /// Accesses the items in the given section.
        subscript(section: MenuBarSection.Name) -> [MenuBarItem] {
            get { storage[section, default: []] }
            set { storage[section] = newValue }
        }
    }

    /// A pair of control items, taken from a list of menu bar items
    /// during a menu bar item cache operation.
    private struct ControlItemPair {
        let hidden: MenuBarItem
        let alwaysHidden: MenuBarItem?

        init?(items: inout [MenuBarItem]) {
            guard let hidden = items.removeFirst(matching: .hiddenControlItem) else {
                return nil
            }
            self.hidden = hidden
            self.alwaysHidden = items.removeFirst(matching: .alwaysHiddenControlItem)
        }
    }

    /// Context maintained during a menu bar item cache operation.
    private struct CacheContext {
        let controlItems: ControlItemPair

        var cache: ItemCache
        var temporarilyShownItems = [(MenuBarItem, TemporarilyShownItemContext)]()
        var shouldClearCachedItemWindowIDs = false

        private(set) lazy var hiddenControlItemBounds = bestBounds(for: controlItems.hidden)
        private(set) lazy var alwaysHiddenControlItemBounds = controlItems.alwaysHidden.map(bestBounds)

        init(controlItems: ControlItemPair, displayID: CGDirectDisplayID?) {
            self.controlItems = controlItems
            self.cache = ItemCache(displayID: displayID)
        }

        func bestBounds(for item: MenuBarItem) -> CGRect {
            Bridging.getWindowBounds(for: item.windowID) ?? item.bounds
        }

        func isValidForCaching(_ item: MenuBarItem) -> Bool {
            if !item.canBeHidden {
                return false
            }
            if item.isSystemClone {
                return false
            }
            if item.isControlItem, item.tag != .visibleControlItem {
                return false
            }
            return true
        }

        mutating func findSection(for item: MenuBarItem) -> MenuBarSection.Name? {
            lazy var itemBounds = bestBounds(for: item)
            return MenuBarSection.Name.allCases.first { section in
                switch section {
                case .visible:
                    return itemBounds.minX >= hiddenControlItemBounds.maxX
                case .hidden:
                    if let alwaysHiddenControlItemBounds {
                        return itemBounds.maxX <= hiddenControlItemBounds.minX &&
                        itemBounds.minX >= alwaysHiddenControlItemBounds.maxX
                    } else {
                        return itemBounds.maxX <= hiddenControlItemBounds.minX
                    }
                case .alwaysHidden:
                    if let alwaysHiddenControlItemBounds {
                        return itemBounds.maxX <= alwaysHiddenControlItemBounds.minX
                    } else {
                        return false
                    }
                }
            }
        }
    }

    /// Caches the given menu bar items, without ensuring that the provided
    /// control items are correctly ordered.
    private func uncheckedCacheItems(
        items: [MenuBarItem],
        controlItems: ControlItemPair,
        displayID: CGDirectDisplayID?
    ) async {
        var context = CacheContext(controlItems: controlItems, displayID: displayID)

        for item in items where context.isValidForCaching(item) {
            if item.sourcePID == nil {
                logger.warning("Missing sourcePID for \(item.logString, privacy: .public)")
                context.shouldClearCachedItemWindowIDs = true
            }

            if let temp = temporarilyShownContext(matching: item) {
                // Cache temporarily shown items as if they were in their original locations.
                // Keep track of them separately and use their return destinations to insert
                // them into the cache once all other items have been handled.
                context.temporarilyShownItems.append((item, temp))
                continue
            }

            if let section = context.findSection(for: item) {
                context.cache[section].append(item)
                continue
            }

            logger.warning("Couldn't find section for caching \(item.logString, privacy: .public)")
            context.shouldClearCachedItemWindowIDs = true
        }

        // Insert temporary items next to their original anchors whenever
        // possible. Two simultaneously shown duplicate items may point at one
        // another, so repeat until no more anchors can be resolved.
        var remainingTemporaryItems = context.temporarilyShownItems
        var insertedItemInPass = true
        while insertedItemInPass, !remainingTemporaryItems.isEmpty {
            insertedItemInPass = false
            for index in remainingTemporaryItems.indices.reversed() {
                let (item, temporaryContext) = remainingTemporaryItems[index]
                context.cache.insert(item, at: temporaryContext.returnDestination)
                if context.cache.address(forWindowID: item.windowID) != nil {
                    remainingTemporaryItems.remove(at: index)
                    insertedItemInPass = true
                }
            }
        }

        // Break circular anchors using the exact section and index captured
        // before the items were moved. This is the OneDrive two-account case:
        // each status item is the other one's nearest return anchor.
        let sectionOrder = MenuBarSection.Name.allCases
        for (item, temporaryContext) in remainingTemporaryItems.sorted(by: { lhs, rhs in
            let lhsSection = sectionOrder.firstIndex(of: lhs.1.originalSection) ?? 0
            let rhsSection = sectionOrder.firstIndex(of: rhs.1.originalSection) ?? 0
            if lhsSection != rhsSection {
                return lhsSection < rhsSection
            }
            return lhs.1.originalIndex < rhs.1.originalIndex
        }) {
            let section = temporaryContext.originalSection
            let index = temporaryContext.originalIndex.clamped(to: 0...context.cache[section].count)
            context.cache[section].insert(item, at: index)
            logTemporaryItemEvent(
                "TEMP_CACHE_FALLBACK",
                context: temporaryContext,
                item: item,
                details: "section=\(section.logString) index=\(index) reason=circular-anchor",
                level: .warning
            )
        }

        if context.shouldClearCachedItemWindowIDs {
            logger.info("Clearing cached menu bar item windowIDs")
            await cacheActor.clearCachedItemWindowIDs() // Ensure next cache isn't skipped.
        }

        guard !itemCache.hasSamePublishedLayout(as: context.cache) else {
            logger.debug("Not updating menu bar item cache, as items haven't changed")
            return
        }

        itemCache = context.cache
        logger.debug("Updated menu bar item cache")
    }

    /// Caches the current menu bar items, regardless of whether the
    /// items have changed since the previous cache.
    ///
    /// Before caching, this method ensures that the control items for
    /// the hidden and always-hidden sections are correctly ordered,
    /// arranging them into valid positions if needed.
    func cacheItemsRegardless(_ currentItemWindowIDs: [CGWindowID]? = nil) async {
        await cacheActor.runCacheTask { [weak self] in
            guard let self else {
                return
            }

            guard !lastMoveOperationOccurred(within: .seconds(1)) else {
                logger.debug("Skipping menu bar item cache due to recent item movement")
                return
            }

            let displayID = Bridging.getActiveMenuBarDisplayID()
            var items = await MenuBarItem.getMenuBarItems(option: .activeSpace)

            let itemWindowIDs = currentItemWindowIDs ?? items.reversed().map { $0.windowID }
            await cacheActor.updateCachedItemWindowIDs(itemWindowIDs)

            let liveTags = Set(items.map(\.tag))
            let removedUUIDs = MenuBarItemTag.Namespace.pruneUUIDCache(
                keeping: Set(itemWindowIDs)
            )
            let removedTimeouts = pruneMoveOperationTimeouts(
                keeping: liveTags
            )
            if removedUUIDs > 0 || removedTimeouts > 0 {
                diagnosticLogger.write(
                    "CACHE_PRUNE uuid=\(removedUUIDs) moveTimeouts=\(removedTimeouts) " +
                    "liveWindows=\(itemWindowIDs.count) liveTags=\(liveTags.count)"
                )
            }

            guard let controlItems = ControlItemPair(items: &items) else {
                // ???: Is clearing the cache the best thing to do here?
                logger.warning("Missing control item for hidden section, clearing menu bar item cache")
                itemCache = ItemCache(displayID: nil)
                return
            }

            await enforceControlItemOrder(controlItems: controlItems)
            await uncheckedCacheItems(items: items, controlItems: controlItems, displayID: displayID)
        }
    }

    /// Caches the current menu bar items, if the items have changed
    /// since the previous cache.
    ///
    /// Before caching, this method ensures that the control items for
    /// the hidden and always-hidden sections are correctly ordered,
    /// arranging them into valid positions if needed.
    func cacheItemsIfNeeded() async {
        let itemWindowIDs = Bridging.getMenuBarWindowList(option: [.itemsOnly, .activeSpace])
        if await cacheActor.cachedItemWindowIDs != itemWindowIDs {
            await cacheItemsRegardless(itemWindowIDs)
        }
    }
}

// MARK: - Event Helpers

extension MenuBarItemManager {
    /// An error that can occur during menu bar item event operations.
    enum EventError: CustomStringConvertible, LocalizedError {
        /// A generic indication of a failure.
        case cannotComplete
        /// An event source cannot be created or is otherwise invalid.
        case invalidEventSource
        /// The location of the mouse cannot be found.
        case missingMouseLocation
        /// A failure during the creation of an event.
        case eventCreationFailure(MenuBarItem)
        /// A timeout during an event operation.
        case eventOperationTimeout(MenuBarItem)
        /// A menu bar item is not movable.
        case itemNotMovable(MenuBarItem)
        /// A timeout waiting for a menu bar item to respond to an event.
        case itemResponseTimeout(MenuBarItem)
        /// A menu bar item's bounds cannot be found.
        case missingItemBounds(MenuBarItem)
        /// A layout-editor move cannot be kept on a physical menu bar.
        case unsafeLayoutMove(MenuBarItem)

        var description: String {
            switch self {
            case .cannotComplete:
                "\(Self.self).cannotComplete"
            case .invalidEventSource:
                "\(Self.self).invalidEventSource"
            case .missingMouseLocation:
                "\(Self.self).missingMouseLocation"
            case .eventCreationFailure(let item):
                "\(Self.self).eventCreationFailure(item: \(item.tag))"
            case .eventOperationTimeout(let item):
                "\(Self.self).eventOperationTimeout(item: \(item.tag))"
            case .itemNotMovable(let item):
                "\(Self.self).itemNotMovable(item: \(item.tag))"
            case .itemResponseTimeout(let item):
                "\(Self.self).itemResponseTimeout(item: \(item.tag))"
            case .missingItemBounds(let item):
                "\(Self.self).missingItemBounds(item: \(item.tag))"
            case .unsafeLayoutMove(let item):
                "\(Self.self).unsafeLayoutMove(item: \(item.tag))"
            }
        }

        var errorDescription: String? {
            switch self {
            case .cannotComplete:
                "Operation could not be completed"
            case .invalidEventSource:
                "Invalid event source"
            case .missingMouseLocation:
                "Missing mouse location"
            case .eventCreationFailure(let item):
                "Could not create event for \"\(item.displayName)\""
            case .eventOperationTimeout(let item):
                "Event operation timed out for \"\(item.displayName)\""
            case .itemNotMovable(let item):
                "\"\(item.displayName)\" is not movable"
            case .itemResponseTimeout(let item):
                "\"\(item.displayName)\" took too long to respond"
            case .missingItemBounds(let item):
                "Missing bounds rectangle for \"\(item.displayName)\""
            case .unsafeLayoutMove(let item):
                "Could not find a safe on-screen path for \"\(item.displayName)\""
            }
        }

        var recoverySuggestion: String? {
            if case .itemNotMovable = self { return nil }
            if case .unsafeLayoutMove = self {
                return "Make room in the menu bar and try again. Ice stopped the move before macOS could remove the item."
            }
            return "Please try again. If the error persists, please file a bug report."
        }
    }

    /// Returns a Boolean value that indicates whether the user has
    /// paused input for at least the given duration.
    ///
    /// - Parameter duration: The duration that certain types of input
    ///   events must not have occured within in order to return `true`.
    private nonisolated func hasUserPausedInput(for duration: Duration) -> Bool {
        NSEvent.modifierFlags.isEmpty &&
        !MouseHelpers.lastMovementOccurred(within: duration) &&
        !MouseHelpers.lastScrollWheelOccurred(within: duration) &&
        !MouseHelpers.isButtonPressed()
    }

    /// Waits asynchronously for the user to pause input.
    private nonisolated func waitForUserToPauseInput() async throws {
        let waitTask = Task {
            while true {
                try Task.checkCancellation()
                if hasUserPausedInput(for: .milliseconds(50)) {
                    break
                }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        do {
            try await waitTask.value
        } catch {
            throw EventError.cannotComplete
        }
    }

    /// Waits between move operations for a dynamic amount of time,
    /// based on the timestamp of the last move operation.
    private nonisolated func waitForMoveOperationBuffer() async throws {
        if let timestamp = await lastMoveOperationTimestamp {
            let buffer = max(.milliseconds(25) - timestamp.duration(to: .now), .zero)
            logger.debug("Move operation buffer: \(buffer)")
            do {
                try await Task.sleep(for: buffer)
            } catch {
                throw EventError.cannotComplete
            }
        }
    }

    /// Waits for the given duration between event operations.
    ///
    /// Since most event operations must perform cleanup or otherwise
    /// run to completion, this method ignores task cancellation.
    private nonisolated func eventSleep(for duration: Duration = .milliseconds(25)) async {
        let task = Task {
            try? await Task.sleep(for: duration)
        }
        await task.value
    }

    /// Returns the current bounds for the given item.
    private nonisolated func getCurrentBounds(for item: MenuBarItem) async throws -> CGRect {
        let task = Task.detached(priority: .userInitiated) {
            guard let bounds = Bridging.getWindowBounds(for: item.windowID) else {
                throw EventError.missingItemBounds(item)
            }
            return bounds
        }
        return try await task.value
    }

    /// Returns the current mouse location.
    private nonisolated func getMouseLocation() throws -> CGPoint {
        guard let location = MouseHelpers.locationCoreGraphics else {
            throw EventError.missingMouseLocation
        }
        return location
    }

    /// Returns the process identifier used for click events.
    ///
    /// On macOS 26, this is normally the application that created the item.
    /// Move events use ``getMoveEventPID(for:)`` instead because the status
    /// window itself is hosted by Control Center.
    private nonisolated func getEventPID(for item: MenuBarItem) -> pid_t {
        item.sourcePID ?? item.ownerPID
    }

    /// Returns the process that owns the status window being moved.
    ///
    /// Before macOS 26 the source and owner PIDs are normally identical. On
    /// macOS 26, Control Center owns the WindowServer window for every status
    /// item, so sending the synthetic drag to the source application causes
    /// the event tap to time out.
    private nonisolated func getMoveEventPID(for item: MenuBarItem) -> pid_t {
        Self.moveEventTargetPID(sourcePID: item.sourcePID, ownerPID: item.ownerPID)
    }

    /// Pure helper kept internal so the macOS 26 routing rule can be tested
    /// without creating WindowServer-backed menu bar items.
    static nonisolated func moveEventTargetPID(sourcePID _: pid_t?, ownerPID: pid_t) -> pid_t {
        ownerPID
    }

    /// Returns an event source for a menu bar item event operation.
    private nonisolated func getEventSource(
        with stateID: CGEventSourceStateID = .hidSystemState
    ) throws -> CGEventSource {
        enum Context {
            static var cache = [CGEventSourceStateID: CGEventSource]()
        }
        if let source = Context.cache[stateID] {
            return source
        }
        guard let source = CGEventSource(stateID: stateID) else {
            throw EventError.invalidEventSource
        }
        Context.cache[stateID] = source
        return source
    }

    /// Prevents local events from being suppressed.
    private nonisolated func permitLocalEvents() throws {
        let source = try getEventSource(with: .combinedSessionState)
        let states: [CGEventSuppressionState] = [
            .eventSuppressionStateRemoteMouseDrag,
            .eventSuppressionStateSuppressionInterval,
        ]
        for state in states {
            source.setLocalEventsFilterDuringSuppressionState(.permitAllEvents, state: state)
        }
        source.localEventsSuppressionInterval = 0
    }

    /// Posts an event to the given menu bar item and waits until
    /// it is received before returning.
    ///
    /// - Parameters:
    ///   - event: The event to post.
    ///   - item: The menu bar item that the event targets.
    ///   - timeout: The base duration to wait before throwing an error.
    ///     The value of this parameter is multiplied by `count` to
    ///     produce the actual timeout duration.
    ///   - count: The number of times to repeat the operation. As it
    ///     is considerably more efficient, prefer increasing this value
    ///     over repeatedly calling `postEventWithBarrier`.
    private nonisolated func postEventWithBarrier(
        _ event: CGEvent,
        to item: MenuBarItem,
        timeout: Duration,
        repeating count: Int = 1
    ) async throws {
        guard
            let entryEvent = CGEvent.uniqueNullEvent(),
            let exitEvent = CGEvent.uniqueNullEvent()
        else {
            throw EventError.eventCreationFailure(item)
        }

        let pid = getEventPID(for: item)
        event.setTargetPID(pid)

        let firstLocation = EventTap.Location.pid(pid)
        let secondLocation = EventTap.Location.sessionEventTap

        var count = count
        var eventTaps = [EventTap]()

        let timeoutTask = Task(timeout: timeout * count) {
            try await withCheckedThrowingContinuation { continuation in
                // Listen for the following events at the first location
                // and perform the following actions:
                //
                // - Entry event: Decrement the count and post the real
                //   event to the second location (handled in EventTap 2).
                // - Exit event: Resume the continuation.
                //
                // These events serve as start (or continue) and stop
                // signals, and are discarded.
                let eventTap1 = EventTap(
                    label: "EventTap 1",
                    type: .null,
                    location: firstLocation,
                    placement: .headInsertEventTap,
                    option: .defaultTap
                ) { tap, rEvent in
                    if rEvent.matches(entryEvent, byIntegerFields: [.eventSourceUserData]) {
                        count -= 1
                        event.post(to: secondLocation)
                        return nil
                    }
                    if rEvent.matches(exitEvent, byIntegerFields: [.eventSourceUserData]) {
                        tap.disable()
                        continuation.resume()
                        return nil
                    }
                    return rEvent
                }

                // Listen for the real event at the second location and,
                // depending on the count, post either the entry or exit
                // event to the first location (handled in EventTap 1).
                let eventTap2 = EventTap(
                    label: "EventTap 2",
                    type: event.type,
                    location: secondLocation,
                    placement: .tailAppendEventTap,
                    option: .listenOnly
                ) { tap, rEvent in
                    guard rEvent.matches(event, byIntegerFields: CGEventField.menuBarItemEventFields) else {
                        return rEvent
                    }
                    if count <= 0 {
                        tap.disable()
                        exitEvent.post(to: firstLocation)
                    } else {
                        entryEvent.post(to: firstLocation)
                    }
                    rEvent.setTargetPID(pid)
                    return rEvent
                }

                // Keep the taps alive.
                eventTaps.append(eventTap1)
                eventTaps.append(eventTap2)

                Task {
                    await withTaskCancellationHandler {
                        eventTap1.enable()
                        eventTap2.enable()
                        entryEvent.post(to: firstLocation)
                    } onCancel: {
                        eventTap1.disable()
                        eventTap2.disable()
                        continuation.resume(throwing: CancellationError())
                    }
                }
            }
        }
        do {
            try await timeoutTask.value
        } catch is TaskTimeoutError {
            throw EventError.eventOperationTimeout(item)
        } catch {
            throw EventError.cannotComplete
        }
    }

    /// Casts forbidden magic to make a menu bar item receive and
    /// respond to an event during a move operation.
    ///
    /// - Parameters:
    ///   - event: The event to post.
    ///   - item: The menu bar item that the event targets.
    ///   - timeout: The base duration to wait before throwing an error.
    ///     The value of this parameter is multiplied by `count` to
    ///     produce the actual timeout duration.
    ///   - count: The number of times to repeat the operation. As it
    ///     is considerably more efficient, prefer increasing this value
    ///     over repeatedly calling `scrombleEvent`.
    private nonisolated func scrombleEvent(
        _ event: CGEvent,
        item: MenuBarItem,
        timeout: Duration,
        repeating count: Int = 1
    ) async throws {
        guard
            let entryEvent = CGEvent.uniqueNullEvent(),
            let exitEvent = CGEvent.uniqueNullEvent()
        else {
            throw EventError.eventCreationFailure(item)
        }

        let pid = getMoveEventPID(for: item)
        event.setTargetPID(pid)

        let firstLocation = EventTap.Location.pid(pid)
        let secondLocation = EventTap.Location.sessionEventTap

        var count = count
        var eventTaps = [EventTap]()

        let timeoutTask = Task(timeout: timeout * count) {
            try await withCheckedThrowingContinuation { continuation in
                // Listen for the following events at the first location
                // and perform the following actions:
                //
                // - Entry event: Decrement the count and post the real
                //   event to the second location (handled in EventTap 2).
                // - Exit event: Resume the continuation.
                //
                // These events serve as start (or continue) and stop
                // signals, and are discarded.
                let eventTap1 = EventTap(
                    label: "EventTap 1",
                    type: .null,
                    location: firstLocation,
                    placement: .headInsertEventTap,
                    option: .defaultTap
                ) { tap, rEvent in
                    if rEvent.matches(entryEvent, byIntegerFields: [.eventSourceUserData]) {
                        count -= 1
                        event.post(to: secondLocation)
                        return nil
                    }
                    if rEvent.matches(exitEvent, byIntegerFields: [.eventSourceUserData]) {
                        tap.disable()
                        continuation.resume()
                        return nil
                    }
                    return rEvent
                }

                // Listen for the real event at the second location and
                // post the real event to the first location (handled in
                // EventTap 3).
                let eventTap2 = EventTap(
                    label: "EventTap 2",
                    type: event.type,
                    location: secondLocation,
                    placement: .tailAppendEventTap,
                    option: .listenOnly
                ) { tap, rEvent in
                    guard rEvent.matches(event, byIntegerFields: CGEventField.menuBarItemEventFields) else {
                        return rEvent
                    }
                    if count <= 0 {
                        tap.disable()
                    }
                    event.post(to: firstLocation)
                    rEvent.setTargetPID(pid)
                    return rEvent
                }

                // Listen for the real event at the first location and,
                // depending on the count, post either the entry or exit
                // event to the first location (handled in EventTap 1).
                let eventTap3 = EventTap(
                    label: "EventTap 3",
                    type: event.type,
                    location: firstLocation,
                    placement: .headInsertEventTap,
                    option: .listenOnly
                ) { tap, rEvent in
                    guard rEvent.matches(event, byIntegerFields: CGEventField.menuBarItemEventFields) else {
                        return rEvent
                    }
                    if count <= 0 {
                        tap.disable()
                        exitEvent.post(to: firstLocation)
                    } else {
                        entryEvent.post(to: firstLocation)
                    }
                    rEvent.setTargetPID(pid)
                    return rEvent
                }

                // Keep the taps alive.
                eventTaps.append(eventTap1)
                eventTaps.append(eventTap2)
                eventTaps.append(eventTap3)

                Task {
                    await withTaskCancellationHandler {
                        eventTap1.enable()
                        eventTap2.enable()
                        eventTap3.enable()
                        entryEvent.post(to: firstLocation)
                    } onCancel: {
                        eventTap1.disable()
                        eventTap2.disable()
                        eventTap3.disable()
                        continuation.resume(throwing: CancellationError())
                    }
                }
            }
        }
        do {
            try await timeoutTask.value
        } catch is TaskTimeoutError {
            throw EventError.eventOperationTimeout(item)
        } catch {
            throw EventError.cannotComplete
        }
    }
}

// MARK: - Moving Items

extension MenuBarItemManager {
    /// The subsystem that requested a move operation.
    enum MoveOrigin: String {
        case internalOperation = "internal"
        case layoutEditor = "layout-editor"
        case automation
    }

    /// The WindowServer view used to verify a completed move.
    private enum MovePositionVerification {
        /// Layout-editor moves reveal every endpoint on one physical display.
        case visibleLayout(displayID: CGDirectDisplayID)
        /// Internal and automation moves may end in macOS' off-screen parking
        /// area and must therefore use the exact live window rectangles.
        case liveWindowBounds

        var logString: String {
            switch self {
            case .visibleLayout(let displayID):
                "visible-layout(displayID=\(displayID))"
            case .liveWindowBounds:
                "live-window-bounds"
            }
        }
    }

    /// Destinations for menu bar item move operations.
    enum MoveDestination {
        /// The destination to the left of the given target item.
        case leftOfItem(MenuBarItem)
        /// The destination to the right of the given target item.
        case rightOfItem(MenuBarItem)

        /// The destination's target item.
        var targetItem: MenuBarItem {
            switch self {
            case .leftOfItem(let item), .rightOfItem(let item): item
            }
        }

        /// A string to use for logging purposes.
        var logString: String {
            switch self {
            case .leftOfItem(let item): "left of \(item.logString)"
            case .rightOfItem(let item): "right of \(item.logString)"
            }
        }
    }

    /// State temporarily owned while a layout-editor move is performed on the
    /// real, visible menu bar instead of in macOS' off-screen parking area.
    private struct LayoutMoveRevealContext {
        struct SectionState {
            let controlItem: ControlItem
            let state: ControlItem.HidingState
        }

        let originalStates: [SectionState]
        let expectedStates: [SectionState]
        let originalShowOnHoverAllowed: Bool
        let displayID: CGDirectDisplayID
    }

    /// Exposes all native sections for a layout-editor move. This makes the
    /// synthesized Command-drag equivalent to a user drag on the real menu bar;
    /// an off-screen mouse-up can otherwise remove Control Center items.
    private func beginLayoutMoveReveal(
        item: MenuBarItem,
        destination: MoveDestination
    ) throws -> LayoutMoveRevealContext {
        guard
            oneDriveNativeRevealContext == nil,
            let appState,
            let displayID = itemCache.displayID ?? NSScreen.screenWithActiveMenuBar?.displayID
        else {
            diagnosticLogger.write(
                "LAYOUT_MOVE_REVEAL_REJECTED item=\(item.tag) target=\(destination.targetItem.tag) " +
                "reason=missing-state-or-conflicting-reveal",
                level: .warning
            )
            throw EventError.unsafeLayoutMove(item)
        }

        let menuBarManager = appState.menuBarManager
        let originalStates = menuBarManager.sections.map {
            LayoutMoveRevealContext.SectionState(controlItem: $0.controlItem, state: $0.controlItem.state)
        }
        let originalShowOnHoverAllowed = menuBarManager.showOnHoverAllowed

        menuBarManager.iceBarPanel.close()
        menuBarManager.showOnHoverAllowed = false
        for section in menuBarManager.sections {
            section.controlItem.state = .showSection
        }

        let expectedStates = menuBarManager.sections.map {
            LayoutMoveRevealContext.SectionState(controlItem: $0.controlItem, state: $0.controlItem.state)
        }
        diagnosticLogger.write(
            "LAYOUT_MOVE_REVEAL_START item=\(item.tag) windowID=\(item.windowID) " +
            "target=\(destination.targetItem.tag) targetWindowID=\(destination.targetItem.windowID) " +
            "displayID=\(displayID)"
        )
        return LayoutMoveRevealContext(
            originalStates: originalStates,
            expectedStates: expectedStates,
            originalShowOnHoverAllowed: originalShowOnHoverAllowed,
            displayID: displayID
        )
    }

    /// Restores the section states only while this operation still owns them.
    private func finishLayoutMoveReveal(_ context: LayoutMoveRevealContext, reason: String) {
        guard let appState else {
            return
        }
        let stillOwnsStates = context.expectedStates.allSatisfy {
            $0.controlItem.state == $0.state
        }
        if stillOwnsStates {
            // Restore the regular hidden shield before the always-hidden one,
            // preventing an intermediate flash of the far-left section.
            for state in context.originalStates.sorted(by: { lhs, rhs in
                let lhsIsHidden = lhs.controlItem.identifier == .hidden
                let rhsIsHidden = rhs.controlItem.identifier == .hidden
                return lhsIsHidden && !rhsIsHidden
            }) {
                state.controlItem.state = state.state
            }
        }
        appState.menuBarManager.showOnHoverAllowed = context.originalShowOnHoverAllowed
        diagnosticLogger.write(
            "LAYOUT_MOVE_REVEAL_FINISH reason=\(reason) displayID=\(context.displayID) " +
            "restored=\(stillOwnsStates)",
            level: stillOwnsStates ? .info : .warning
        )
    }

    /// Waits until a move endpoint is both on the requested display and stable.
    private nonisolated func waitForStableLayoutMoveItem(
        _ item: MenuBarItem,
        on displayID: CGDirectDisplayID,
        timeout: Duration = .seconds(2)
    ) async -> CGRect? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        let displayBounds = CGDisplayBounds(displayID)
        var stableBounds: CGRect?
        var stableSince: ContinuousClock.Instant?

        repeat {
            guard
                let bounds = Bridging.getWindowBounds(for: item.windowID),
                Bridging.isWindowOnScreen(item.windowID),
                displayBounds.intersects(bounds)
            else {
                stableBounds = nil
                stableSince = nil
                await eventSleep(for: .milliseconds(50))
                continue
            }

            if let previous = stableBounds,
               abs(previous.minX - bounds.minX) <= 1,
               abs(previous.minY - bounds.minY) <= 1,
               abs(previous.width - bounds.width) <= 1,
               abs(previous.height - bounds.height) <= 1 {
                if let stableSince, stableSince.duration(to: clock.now) >= .milliseconds(200) {
                    return bounds
                }
            } else {
                stableBounds = bounds
                stableSince = clock.now
            }
            await eventSleep(for: .milliseconds(50))
        } while clock.now < deadline

        return nil
    }

    /// Verifies both endpoints after the native section reveal has settled.
    private func prepareSafeLayoutMove(
        item: MenuBarItem,
        destination: MoveDestination,
        displayID: CGDirectDisplayID
    ) async throws {
        async let sourceBounds = waitForStableLayoutMoveItem(item, on: displayID)
        async let targetBounds = waitForStableLayoutMoveItem(destination.targetItem, on: displayID)
        let sourceResult = await sourceBounds
        let targetResult = await targetBounds
        guard let source = sourceResult, let target = targetResult else {
            diagnosticLogger.write(
                "LAYOUT_MOVE_PREFLIGHT_FAILED item=\(item.tag) windowID=\(item.windowID) " +
                "target=\(destination.targetItem.tag) targetWindowID=\(destination.targetItem.windowID) " +
                "displayID=\(displayID) sourceStable=\(sourceResult != nil) " +
                "targetStable=\(targetResult != nil)",
                level: .warning
            )
            throw EventError.unsafeLayoutMove(item)
        }
        diagnosticLogger.write(
            "LAYOUT_MOVE_PREFLIGHT_READY item=\(item.tag) windowID=\(item.windowID) " +
            "target=\(destination.targetItem.tag) targetWindowID=\(destination.targetItem.windowID) " +
            "displayID=\(displayID) sourceBounds=\(NSStringFromRect(source)) " +
            "targetBounds=\(NSStringFromRect(target))"
        )
    }

    /// Returns the default timeout for move operations associated
    /// with the given item.
    private func getDefaultMoveOperationTimeout(for item: MenuBarItem) -> Duration {
        if item.isBentoBox {
            // Bento Boxes (i.e. Control Center groups) generally
            // take a little longer to respond.
            return .milliseconds(100)
        }
        return .milliseconds(50)
    }

    /// Returns the cached timeout for move operations associated
    /// with the given item.
    private func getMoveOperationTimeout(for item: MenuBarItem) -> Duration {
        if let timeout = moveOperationTimeouts[item.tag] {
            return timeout
        }
        return getDefaultMoveOperationTimeout(for: item)
    }

    /// Updates the cached timeout for move operations associated
    /// with the given item.
    private func updateMoveOperationTimeout(_ timeout: Duration, for item: MenuBarItem) {
        let current = getMoveOperationTimeout(for: item)
        let average = (timeout + current) / 2
        let clamped = average.clamped(min: .milliseconds(25), max: .milliseconds(150))
        moveOperationTimeouts[item.tag] = clamped
    }

    /// Removes adaptive move timeouts for items that no longer exist.
    private func pruneMoveOperationTimeouts(keeping validTags: Set<MenuBarItemTag>) -> Int {
        let previousCount = moveOperationTimeouts.count
        moveOperationTimeouts = moveOperationTimeouts.filter { validTags.contains($0.key) }
        return previousCount - moveOperationTimeouts.count
    }

    /// Returns the target points for creating the events needed to
    /// move a menu bar item to the given destination.
    private nonisolated func getTargetPoints(
        forMoving item: MenuBarItem,
        to destination: MoveDestination
    ) async throws -> (start: CGPoint, end: CGPoint) {
        let itemBounds = try await getCurrentBounds(for: item)
        let targetBounds = try await getCurrentBounds(for: destination.targetItem)
        switch destination {
        case .leftOfItem:
            var start = CGPoint(x: targetBounds.minX, y: targetBounds.minY)
            var end = start
            if itemBounds.maxX <= targetBounds.minX {
                // Direction of movement: ->
                end.x -= itemBounds.width
            } else {
                // Direction of movement: <-
                start.x -= 1
            }
            return (start, end)
        case .rightOfItem:
            var start = CGPoint(x: targetBounds.maxX, y: targetBounds.minY)
            var end = start
            if itemBounds.minX <= targetBounds.maxX {
                // Direction of movement: ->
                end.x -= itemBounds.width
            } else {
                // Direction of movement: <-
                start.x += 1
            }
            return (start, end)
        }
    }

    /// Returns the current bounds for both move operands from one CoreGraphics
    /// window description snapshot.
    private nonisolated func getMoveBoundsSnapshot(
        item: MenuBarItem,
        target: MenuBarItem
    ) async throws -> (item: CGRect, target: CGRect) {
        let task = Task.detached(priority: .userInitiated) {
            let activeSpaceID = Bridging.getActiveSpaceID()
            guard Bridging.isWindowOnSpace(item.windowID, activeSpaceID) else {
                throw EventError.missingItemBounds(item)
            }
            guard Bridging.isWindowOnSpace(target.windowID, activeSpaceID) else {
                throw EventError.missingItemBounds(target)
            }

            let windows = WindowInfo.createWindows(from: [item.windowID, target.windowID])
            guard let itemBounds = windows.first(where: { $0.windowID == item.windowID })?.bounds else {
                throw EventError.missingItemBounds(item)
            }
            guard let targetBounds = windows.first(where: { $0.windowID == target.windowID })?.bounds else {
                throw EventError.missingItemBounds(target)
            }
            return (itemBounds, targetBounds)
        }
        return try await task.value
    }

    /// Returns a Boolean value that indicates whether the given menu bar
    /// item has the correct position, relative to the given destination.
    private func itemHasCorrectPosition(
        item: MenuBarItem,
        for destination: MoveDestination,
        verification: MovePositionVerification
    ) async throws -> Bool {
        let side: MenuBarMoveSafety.Side = switch destination {
        case .leftOfItem: .left
        case .rightOfItem: .right
        }

        switch verification {
        case .visibleLayout(let displayID):
            // Layout-editor endpoints are deliberately revealed on one display.
            // Ordinal verification is robust while the menu bar reflows and
            // remains independent of the user's status-item spacing setting.
            let items = await MenuBarItem
                .getMenuBarItems(
                    on: displayID,
                    option: .activeSpace,
                    resolveSourcePID: false
                )
                .sorted {
                    if $0.bounds.minX == $1.bounds.minX {
                        return $0.windowID < $1.windowID
                    }
                    return $0.bounds.minX < $1.bounds.minX
                }
            let orderedWindowIDs = items.map(\.windowID)
            guard orderedWindowIDs.contains(item.windowID) else {
                throw EventError.missingItemBounds(item)
            }
            guard orderedWindowIDs.contains(destination.targetItem.windowID) else {
                throw EventError.missingItemBounds(destination.targetItem)
            }
            return MenuBarMoveSafety.hasImmediateNeighbor(
                itemWindowID: item.windowID,
                targetWindowID: destination.targetItem.windowID,
                orderedWindowIDs: orderedWindowIDs,
                side: side
            )

        case .liveWindowBounds:
            // Hidden and always-hidden items are parked outside all displays.
            // Read only the two exact window IDs in one snapshot; this avoids
            // both the on-screen filter and cross-display ordering ambiguity.
            let bounds = try await getMoveBoundsSnapshot(
                item: item,
                target: destination.targetItem
            )
            return MenuBarMoveSafety.edgesAreAdjacent(
                itemBounds: bounds.item,
                targetBounds: bounds.target,
                side: side
            )
        }
    }

    /// Waits for AppKit to finish settling an item at its requested
    /// destination. A changed origin only proves that the drag was received;
    /// apps can still move their status item again before the mouse-up has
    /// finished processing.
    private nonisolated func waitForMoveToSettle(
        item: MenuBarItem,
        at destination: MoveDestination,
        verification: MovePositionVerification,
        timeout: Duration = .milliseconds(500)
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        repeat {
            try Task.checkCancellation()
            if try await itemHasCorrectPosition(
                item: item,
                for: destination,
                verification: verification
            ) {
                return true
            }
            try await Task.sleep(for: .milliseconds(10))
        } while clock.now < deadline

        return try await itemHasCorrectPosition(
            item: item,
            for: destination,
            verification: verification
        )
    }

    /// Waits for a menu bar item to respond to a series of previously
    /// posted move events.
    ///
    /// - Parameters:
    ///   - item: The item to check for a response.
    ///   - initialOrigin: The origin of the item before the events were posted.
    ///   - timeout: The duration to wait before throwing an error.
    private nonisolated func waitForMoveEventResponse(
        from item: MenuBarItem,
        initialOrigin: CGPoint,
        timeout: Duration
    ) async throws -> CGPoint {
        let responseTask = Task.detached {
            while true {
                try Task.checkCancellation()
                let origin = try await self.getCurrentBounds(for: item).origin
                if origin != initialOrigin {
                    return origin
                }
            }
        }
        let timeoutTask = Task(timeout: timeout) {
            try await withTaskCancellationHandler {
                try await responseTask.value
            } onCancel: {
                responseTask.cancel()
            }
        }
        do {
            let origin = try await timeoutTask.value
            logger.debug(
                """
                Item responded to events with new origin: \
                \(String(describing: origin), privacy: .public)
                """
            )
            return origin
        } catch let error as EventError {
            throw error
        } catch is TaskTimeoutError {
            throw EventError.itemResponseTimeout(item)
        } catch {
            throw EventError.cannotComplete
        }
    }

    /// Creates and posts a series of events to move a menu bar item
    /// to the given destination.
    ///
    /// - Parameters:
    ///   - item: The menu bar item to move.
    ///   - destination: The destination to move the menu bar item.
    private func postMoveEvents(
        item: MenuBarItem,
        destination: MoveDestination,
        safeDisplayID: CGDirectDisplayID?
    ) async throws {
        try await eventSemaphore.waitUnlessCancelled()
        defer {
            eventSemaphore.signal()
        }

        let sourceBounds = try await getCurrentBounds(for: item)
        let targetBounds = try await getCurrentBounds(for: destination.targetItem)
        var itemOrigin = sourceBounds.origin
        let targetPoints = try await getTargetPoints(forMoving: item, to: destination)

        if let safeDisplayID {
            let displayBounds = CGDisplayBounds(safeDisplayID)
            guard
                Bridging.isWindowOnScreen(item.windowID),
                Bridging.isWindowOnScreen(destination.targetItem.windowID),
                MenuBarMoveSafety.endpointsAreSafe(
                    start: targetPoints.start,
                    end: targetPoints.end,
                    sourceBounds: sourceBounds,
                    targetBounds: targetBounds,
                    displayBounds: displayBounds
                )
            else {
                diagnosticLogger.write(
                    "LAYOUT_MOVE_GEOMETRY_REJECTED item=\(item.tag) windowID=\(item.windowID) " +
                    "target=\(destination.targetItem.tag) targetWindowID=\(destination.targetItem.windowID) " +
                    "displayID=\(safeDisplayID) start=\(NSStringFromPoint(targetPoints.start)) " +
                    "end=\(NSStringFromPoint(targetPoints.end)) sourceBounds=\(NSStringFromRect(sourceBounds)) " +
                    "targetBounds=\(NSStringFromRect(targetBounds))",
                    level: .warning
                )
                throw EventError.unsafeLayoutMove(item)
            }
        }
        diagnosticLogger.write(
            "MOVE_GEOMETRY item=\(item.tag) windowID=\(item.windowID) " +
            "target=\(destination.targetItem.tag) targetWindowID=\(destination.targetItem.windowID) " +
            "safeDisplayID=\(safeDisplayID.map(String.init) ?? "nil") " +
            "start=\(NSStringFromPoint(targetPoints.start)) end=\(NSStringFromPoint(targetPoints.end)) " +
            "sourceBounds=\(NSStringFromRect(sourceBounds)) targetBounds=\(NSStringFromRect(targetBounds))"
        )
        let eventPID = getMoveEventPID(for: item)
        diagnosticLogger.write(
            "MOVE_EVENT_ROUTE item=\(item.tag) windowID=\(item.windowID) " +
            "sourcePID=\(item.sourcePID.map(String.init) ?? "nil") ownerPID=\(item.ownerPID) " +
            "targetPID=\(eventPID) route=window-owner"
        )
        let mouseLocation = try getMouseLocation()
        let source = try getEventSource()

        try permitLocalEvents()

        guard
            let mouseDown = CGEvent.menuBarItemEvent(
                item: item,
                source: source,
                type: .move(.mouseDown),
                location: targetPoints.start
            ),
            let mouseUp = CGEvent.menuBarItemEvent(
                item: destination.targetItem,
                source: source,
                type: .move(.mouseUp),
                location: targetPoints.end
            )
        else {
            throw EventError.eventCreationFailure(item)
        }

        var timeout = getMoveOperationTimeout(for: item)
        logger.debug("Move operation timeout: \(timeout)")

        lastMoveOperationTimestamp = .now
        let cursorLease = MouseHelpers.hideCursor(owner: "move-events:\(item.tag)")
        defer {
            cursorLease.release {
                MouseHelpers.warpCursor(to: mouseLocation)
            }
            lastMoveOperationTimestamp = .now
            updateMoveOperationTimeout(timeout, for: item)
        }

        do {
            try await scrombleEvent(
                mouseDown,
                item: item,
                timeout: timeout
            )
            itemOrigin = try await waitForMoveEventResponse(
                from: item,
                initialOrigin: itemOrigin,
                timeout: timeout
            )
            try await scrombleEvent(
                mouseUp,
                item: item,
                timeout: timeout,
                repeating: 2 // Double mouse up prevents invalid item state.
            )
            itemOrigin = try await waitForMoveEventResponse(
                from: item,
                initialOrigin: itemOrigin,
                timeout: timeout
            )
            timeout -= timeout / 4
        } catch {
            do {
                logger.warning("Move events failed, posting fallback")
                try await scrombleEvent(
                    mouseUp,
                    item: item,
                    timeout: .milliseconds(100), // Fixed timeout for fallback.
                    repeating: 2 // Double mouse up prevents invalid item state.
                )
            } catch {
                // Catch this for logging purposes only. We want to propagate
                // the original error.
                logger.error("Fallback failed with error: \(error, privacy: .public)")
            }
            timeout += timeout / 2
            throw error
        }
    }

    /// Moves a menu bar item to the given destination.
    ///
    /// - Parameters:
    ///   - item: The menu bar item to move.
    ///   - destination: The destination to move the item to.
    func move(
        item: MenuBarItem,
        to destination: MoveDestination,
        origin: MoveOrigin = .internalOperation
    ) async throws {
        guard item.isMovable else {
            throw EventError.itemNotMovable(item)
        }
        guard let appState else {
            throw EventError.cannotComplete
        }

        try await moveSemaphore.waitUnlessCancelled()
        defer {
            moveSemaphore.signal()
        }

        let ownsLayoutEditorState = origin == .layoutEditor
        if ownsLayoutEditorState {
            layoutEditorMoveGeneration &+= 1
            isLayoutEditorMoveActive = true
        }
        defer {
            if ownsLayoutEditorState {
                isLayoutEditorMoveActive = false
                layoutEditorMoveGeneration &+= 1
                appState.automationManager.resumeAfterLayoutEditorMove()
            }
        }

        var revealContext: LayoutMoveRevealContext?
        var revealFinishReason = "failed"
        defer {
            if let revealContext {
                finishLayoutMoveReveal(revealContext, reason: revealFinishReason)
            }
        }

        diagnosticLogger.write(
            "MOVE_START origin=\(origin.rawValue) item=\(item.tag) windowID=\(item.windowID) " +
            "sourcePID=\(item.sourcePID.map(String.init) ?? "nil") " +
            "target=\(destination.targetItem.tag) targetWindowID=\(destination.targetItem.windowID) " +
            "itemSpacer=\(item.tag.isIceSpacer) targetSpacer=\(destination.targetItem.tag.isIceSpacer)"
        )

        do {
            if origin == .layoutEditor {
                let context = try beginLayoutMoveReveal(item: item, destination: destination)
                revealContext = context
                try await prepareSafeLayoutMove(
                    item: item,
                    destination: destination,
                    displayID: context.displayID
                )
            }

            let verification: MovePositionVerification
            if origin == .layoutEditor, let displayID = revealContext?.displayID {
                verification = .visibleLayout(displayID: displayID)
            } else {
                verification = .liveWindowBounds
            }

            try await performMove(
                item: item,
                to: destination,
                appState: appState,
                safeDisplayID: revealContext?.displayID,
                verification: verification
            )
            revealFinishReason = "succeeded"
            diagnosticLogger.write(
                "MOVE_SUCCESS origin=\(origin.rawValue) item=\(item.tag) windowID=\(item.windowID) " +
                "target=\(destination.targetItem.tag) targetWindowID=\(destination.targetItem.windowID)"
            )
        } catch {
            diagnosticLogger.write(
                "MOVE_FAILURE origin=\(origin.rawValue) item=\(item.tag) windowID=\(item.windowID) " +
                "target=\(destination.targetItem.tag) targetWindowID=\(destination.targetItem.windowID) " +
                "sourceExists=\(Bridging.getWindowBounds(for: item.windowID) != nil) " +
                "targetExists=\(Bridging.getWindowBounds(for: destination.targetItem.windowID) != nil) " +
                "error=\(String(describing: error))",
                level: .error
            )
            throw error
        }
    }

    /// Performs a move while the caller owns the complete move semaphore.
    private func performMove(
        item: MenuBarItem,
        to destination: MoveDestination,
        appState: AppState,
        safeDisplayID: CGDirectDisplayID?,
        verification: MovePositionVerification
    ) async throws {
        try await waitForUserToPauseInput()

        appState.hidEventManager.stopAll()
        defer {
            appState.hidEventManager.startAll()
        }

        try await waitForMoveOperationBuffer()

        logger.log(
            """
            Moving \(item.logString, privacy: .public) to \
            \(destination.logString, privacy: .public)
            """
        )

        diagnosticLogger.write(
            "MOVE_VERIFICATION_MODE item=\(item.tag) windowID=\(item.windowID) " +
            "targetWindowID=\(destination.targetItem.windowID) mode=\(verification.logString)"
        )

        guard try await !itemHasCorrectPosition(
            item: item,
            for: destination,
            verification: verification
        ) else {
            logger.debug("Item has correct position, cancelling move")
            return
        }

        let maxAttempts = safeDisplayID == nil ? 8 : 3
        for n in 1...maxAttempts {
            guard !Task.isCancelled else {
                throw EventError.cannotComplete
            }
            do {
                if try await itemHasCorrectPosition(
                    item: item,
                    for: destination,
                    verification: verification
                ) {
                    logger.debug("Item has correct position, finished with move")
                    return
                }
                try await postMoveEvents(
                    item: item,
                    destination: destination,
                    safeDisplayID: safeDisplayID
                )
                guard try await waitForMoveToSettle(
                    item: item,
                    at: destination,
                    verification: verification
                ) else {
                    diagnosticLogger.write(
                        "MOVE_POSTCONDITION_FAILURE item=\(item.tag) windowID=\(item.windowID) " +
                        "targetWindowID=\(destination.targetItem.windowID) " +
                        "attempt=\(n) mode=\(verification.logString)",
                        level: .warning
                    )
                    logger.debug(
                        "Attempt \(n, privacy: .public) posted successfully but failed its position postcondition"
                    )
                    throw EventError.itemResponseTimeout(item)
                }
                diagnosticLogger.write(
                    "MOVE_POSTCONDITION_CONFIRMED item=\(item.tag) windowID=\(item.windowID) " +
                    "targetWindowID=\(destination.targetItem.windowID) " +
                    "attempt=\(n) mode=\(verification.logString)"
                )
                logger.debug("Attempt \(n, privacy: .public) succeeded, finished with move")
                return
            } catch {
                logger.debug("Attempt \(n, privacy: .public) failed: \(error, privacy: .public)")
                if let eventError = error as? EventError {
                    switch eventError {
                    case .missingItemBounds, .unsafeLayoutMove:
                        // Retrying after an item or safe endpoint disappears can
                        // only spray more Command-drag events into the menu bar.
                        throw eventError
                    default:
                        break
                    }
                }
                if n < maxAttempts {
                    try await waitForMoveOperationBuffer()
                    continue
                }
                if error is EventError {
                    throw error
                }
                throw EventError.cannotComplete
            }
        }
    }
}

// MARK: - Clicking Items

extension MenuBarItemManager {
    /// The result of locating and pressing a status item through the
    /// Accessibility API. Only immutable values cross back from the detached
    /// AX worker; the AX elements themselves stay on that worker.
    private struct AccessibilityPressAttempt: Sendable {
        enum Outcome: String, Sendable {
            case pressed
            case missingSourceProcess
            case missingExtrasMenuBar
            case missingChildren
            case missingMatchingItem
            case actionFailed
        }

        let outcome: Outcome
        let candidateCount: Int
        let selectedIndex: Int?
        let selectedFrame: CGRect?
        let errorCode: Int32?
    }

    /// The menu bar state captured before revealing OneDrive's real status
    /// item. The expected states are used as an ownership check, so a user
    /// initiated section change is never overwritten when the popup closes.
    private struct OneDriveNativeRevealContext {
        struct SectionState {
            let controlItem: ControlItem
            let state: ControlItem.HidingState
        }

        let originalStates: [SectionState]
        var expectedStates: [SectionState]
        let originalShowOnHoverAllowed: Bool
        let targetDisplayID: CGDirectDisplayID
    }

    /// Returns a copied accessibility attribute.
    private nonisolated static func copyAccessibilityAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    /// Returns the global frame reported for an accessibility element.
    private nonisolated static func accessibilityFrame(of element: AXUIElement) -> CGRect? {
        guard
            let position = copyAccessibilityAttribute(kAXPositionAttribute, from: element) as CFTypeRef?,
            CFGetTypeID(position) == AXValueGetTypeID(),
            let size = copyAccessibilityAttribute(kAXSizeAttribute, from: element) as CFTypeRef?,
            CFGetTypeID(size) == AXValueGetTypeID()
        else {
            return nil
        }

        var point = CGPoint.zero
        var dimensions = CGSize.zero
        let positionValue = unsafeBitCast(position, to: AXValue.self)
        let sizeValue = unsafeBitCast(size, to: AXValue.self)
        guard
            AXValueGetValue(positionValue, .cgPoint, &point),
            AXValueGetValue(sizeValue, .cgSize, &dimensions)
        else {
            return nil
        }
        return CGRect(origin: point, size: dimensions)
    }

    /// Locates the source process' menu extra nearest the WindowServer item
    /// and presses it without changing the physical menu bar layout.
    private nonisolated static func performAccessibilityPress(
        sourcePID: pid_t?,
        expectedFrame: CGRect
    ) -> AccessibilityPressAttempt {
        guard let sourcePID else {
            return AccessibilityPressAttempt(
                outcome: .missingSourceProcess,
                candidateCount: 0,
                selectedIndex: nil,
                selectedFrame: nil,
                errorCode: nil
            )
        }

        let application = AXUIElementCreateApplication(sourcePID)
        AXUIElementSetMessagingTimeout(application, 0.35)

        guard
            let extras = copyAccessibilityAttribute("AXExtrasMenuBar", from: application) as CFTypeRef?,
            CFGetTypeID(extras) == AXUIElementGetTypeID()
        else {
            return AccessibilityPressAttempt(
                outcome: .missingExtrasMenuBar,
                candidateCount: 0,
                selectedIndex: nil,
                selectedFrame: nil,
                errorCode: nil
            )
        }

        let extrasMenuBar = unsafeBitCast(extras, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(extrasMenuBar, 0.35)
        guard
            let children = copyAccessibilityAttribute(kAXChildrenAttribute, from: extrasMenuBar)
                as? [AXUIElement],
            !children.isEmpty
        else {
            return AccessibilityPressAttempt(
                outcome: .missingChildren,
                candidateCount: 0,
                selectedIndex: nil,
                selectedFrame: nil,
                errorCode: nil
            )
        }

        let framedChildren = children.enumerated().compactMap { index, element in
            accessibilityFrame(of: element).map { frame in
                (index: index, element: element, frame: frame)
            }
        }
        let selected: (index: Int, element: AXUIElement, frame: CGRect)?
        if let closest = framedChildren.min(by: { lhs, rhs in
            let lhsDistance = hypot(
                lhs.frame.midX - expectedFrame.midX,
                lhs.frame.midY - expectedFrame.midY
            )
            let rhsDistance = hypot(
                rhs.frame.midX - expectedFrame.midX,
                rhs.frame.midY - expectedFrame.midY
            )
            return lhsDistance < rhsDistance
        }) {
            selected = closest
        } else if children.count == 1, let child = children.first {
            // Some apps omit AXPosition/AXSize for a hidden extra. A sole
            // child is still unambiguous for that source process.
            selected = (0, child, .null)
        } else {
            selected = nil
        }

        guard let selected else {
            return AccessibilityPressAttempt(
                outcome: .missingMatchingItem,
                candidateCount: children.count,
                selectedIndex: nil,
                selectedFrame: nil,
                errorCode: nil
            )
        }

        AXUIElementSetMessagingTimeout(selected.element, 0.35)
        let error = AXUIElementPerformAction(selected.element, kAXPressAction as CFString)
        return AccessibilityPressAttempt(
            outcome: error == .success ? .pressed : .actionFailed,
            candidateCount: children.count,
            selectedIndex: selected.index,
            selectedFrame: selected.frame == .null ? nil : selected.frame,
            errorCode: error == .success ? nil : error.rawValue
        )
    }

    /// Waits for a new on-screen interface window from the source process.
    /// AXPress returning success only means the action was accepted, so this
    /// provides separate evidence about the visible side effect.
    private func waitForNewInterfaceWindow(
        ownerPID: pid_t,
        excluding existingWindowIDs: Set<CGWindowID>,
        timeout: Duration = .milliseconds(1250)
    ) async -> WindowInfo? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        repeat {
            if let window = WindowInfo.createWindows(option: .onScreen).first(where: {
                $0.ownerPID == ownerPID && !existingWindowIDs.contains($0.windowID)
            }) {
                return window
            }
            await eventSleep(for: .milliseconds(50))
        } while clock.now < deadline

        return nil
    }

    /// Reveals the section containing a hidden OneDrive item in the native
    /// menu bar. This changes delimiter lengths only; it never moves the item.
    private func beginOneDriveNativeReveal(
        section: MenuBarSection.Name,
        targetDisplayID: CGDirectDisplayID,
        key: String,
        itemWindowID: CGWindowID
    ) -> Bool {
        guard
            section != .visible,
            let appState
        else {
            return false
        }

        let menuBarManager = appState.menuBarManager
        menuBarManager.iceBarPanel.close()

        if oneDriveNativeRevealContext == nil {
            oneDriveNativeRevealContext = OneDriveNativeRevealContext(
                originalStates: menuBarManager.sections.map {
                    .init(controlItem: $0.controlItem, state: $0.controlItem.state)
                },
                expectedStates: [],
                originalShowOnHoverAllowed: menuBarManager.showOnHoverAllowed,
                targetDisplayID: targetDisplayID
            )
        }

        // Apply the always-hidden shield before exposing the regular hidden
        // section, matching the ordering used by other delimiter-based apps.
        if let alwaysHidden = menuBarManager.section(withName: .alwaysHidden) {
            alwaysHidden.controlItem.state = section == .alwaysHidden ? .showSection : .hideSection
        }
        if let hidden = menuBarManager.section(withName: .hidden) {
            hidden.controlItem.state = .showSection
        }
        if let visible = menuBarManager.section(withName: .visible) {
            visible.controlItem.state = .showSection
        }
        menuBarManager.showOnHoverAllowed = false

        oneDriveNativeRevealContext?.expectedStates = menuBarManager.sections.map {
            .init(controlItem: $0.controlItem, state: $0.controlItem.state)
        }
        diagnosticLogger.write(
            "OD_NATIVE_REVEAL_START key=\(key) windowID=\(itemWindowID) " +
                "section=\(section.logString) targetDisplayID=\(targetDisplayID)"
        )
        return true
    }

    /// Waits for the real status item to remain in a stable position on the
    /// requested display. A successful AXPress against off-screen geometry is
    /// not sufficient because OneDrive anchors its interface to that geometry.
    private func waitForStableOneDriveItem(
        _ item: MenuBarItem,
        on targetDisplayID: CGDirectDisplayID,
        timeout: Duration = .seconds(2)
    ) async -> CGRect? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        let targetBounds = CGDisplayBounds(targetDisplayID)
        var stableBounds: CGRect?
        var stableSince: ContinuousClock.Instant?

        repeat {
            guard let bounds = Bridging.getWindowBounds(for: item.windowID) else {
                stableBounds = nil
                stableSince = nil
                await eventSleep(for: .milliseconds(50))
                continue
            }

            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            guard Bridging.isWindowOnScreen(item.windowID), targetBounds.contains(center) else {
                stableBounds = nil
                stableSince = nil
                await eventSleep(for: .milliseconds(50))
                continue
            }

            if let previous = stableBounds,
               abs(previous.minX - bounds.minX) <= 1,
               abs(previous.minY - bounds.minY) <= 1,
               abs(previous.width - bounds.width) <= 1,
               abs(previous.height - bounds.height) <= 1 {
                if let stableSince, stableSince.duration(to: clock.now) >= .milliseconds(200) {
                    return bounds
                }
            } else {
                stableBounds = bounds
                stableSince = clock.now
            }

            await eventSleep(for: .milliseconds(50))
        } while clock.now < deadline

        return nil
    }

    /// Restores section state after the OneDrive interface has closed.
    private func finishOneDriveNativeReveal(reason: String, generation: Int? = nil) {
        if let generation, generation != oneDriveNativeRevealGeneration {
            return
        }
        guard let context = oneDriveNativeRevealContext, let appState else {
            return
        }

        oneDriveNativeRevealMonitor?.cancel()
        oneDriveNativeRevealMonitor = nil
        oneDriveNativeRevealContext = nil

        let stillOwnsStates = context.expectedStates.allSatisfy {
            $0.controlItem.state == $0.state
        }
        if stillOwnsStates {
            // Restore the main shield before the always-hidden shield so items
            // cannot flash while the original state is being reconstructed.
            for state in context.originalStates.sorted(by: { lhs, rhs in
                let lhsIsHidden = lhs.controlItem.identifier == .hidden
                let rhsIsHidden = rhs.controlItem.identifier == .hidden
                return lhsIsHidden && !rhsIsHidden
            }) {
                state.controlItem.state = state.state
            }
        }
        appState.menuBarManager.showOnHoverAllowed = context.originalShowOnHoverAllowed

        diagnosticLogger.write(
            "OD_NATIVE_REVEAL_FINISH reason=\(reason) generation=\(oneDriveNativeRevealGeneration) " +
                "targetDisplayID=\(context.targetDisplayID) restored=\(stillOwnsStates)",
            level: stillOwnsStates ? .info : .warning
        )
    }

    /// Keeps the native section visible until the interface has remained
    /// closed for 500 ms, avoiding transient WindowServer visibility changes.
    private func monitorOneDriveInterface(_ interface: WindowInfo, key: String) {
        oneDriveNativeRevealGeneration += 1
        let generation = oneDriveNativeRevealGeneration
        let interfaceWindowID = interface.windowID
        oneDriveNativeRevealMonitor?.cancel()
        oneDriveNativeRevealMonitor = Task { [weak self] in
            var missingSince: ContinuousClock.Instant?
            let clock = ContinuousClock()

            while !Task.isCancelled {
                await self?.eventSleep(for: .milliseconds(100))
                guard let self, generation == oneDriveNativeRevealGeneration else {
                    return
                }

                let onScreenWindowIDs = Set(Bridging.getWindowList(option: .onScreen))
                if onScreenWindowIDs.contains(interfaceWindowID) {
                    missingSince = nil
                    continue
                }

                if let missingSince {
                    if missingSince.duration(to: clock.now) >= .milliseconds(500) {
                        diagnosticLogger.write(
                            "OD_NATIVE_REVEAL_INTERFACE_CLOSED key=\(key) " +
                                "interfaceWindowID=\(interfaceWindowID) generation=\(generation)"
                        )
                        finishOneDriveNativeReveal(reason: "interface-closed", generation: generation)
                        return
                    }
                } else {
                    missingSince = clock.now
                }
            }
        }
    }

    /// Activates OneDrive without moving either the status item or its popup.
    /// Hidden items are first revealed in their original native section so
    /// OneDrive can use a valid AppKit anchor on the requested display.
    private func activateOneDriveWithAccessibilityIfPossible(
        item: MenuBarItem,
        mouseButton: CGMouseButton,
        targetDisplayID: CGDirectDisplayID?
    ) async -> Bool {
        guard
            mouseButton == .left,
            item.tag.namespace == .string("com.microsoft.OneDrive")
        else {
            return false
        }

        let key = item.tag.automationKey?
            .replacingOccurrences(of: "\u{1F}", with: "|") ?? String(describing: item.tag)
        guard let sourcePID = item.sourcePID else {
            diagnosticLogger.write(
                "AX_ACTIVATE_ABORT key=\(key) windowID=\(item.windowID) reason=missing-source-pid",
                level: .warning
            )
            return true
        }
        guard let resolvedDisplayID = targetDisplayID ?? NSScreen.screenWithMouse?.displayID ??
            NSScreen.screenWithActiveMenuBar?.displayID
        else {
            diagnosticLogger.write(
                "AX_ACTIVATE_ABORT key=\(key) windowID=\(item.windowID) reason=missing-target-display",
                level: .warning
            )
            return true
        }

        let wasInitiallyOnScreen = Bridging.isWindowOnScreen(item.windowID)
        var didRevealNatively = false
        var expectedFrame = Bridging.getWindowBounds(for: item.windowID) ?? item.bounds
        if !wasInitiallyOnScreen {
            guard let address = itemCache.address(forWindowID: item.windowID) else {
                diagnosticLogger.write(
                    "AX_ACTIVATE_ABORT key=\(key) windowID=\(item.windowID) reason=missing-cache-address",
                    level: .warning
                )
                return true
            }
            didRevealNatively = beginOneDriveNativeReveal(
                section: address.section,
                targetDisplayID: resolvedDisplayID,
                key: key,
                itemWindowID: item.windowID
            )
            guard didRevealNatively else {
                diagnosticLogger.write(
                    "AX_ACTIVATE_ABORT key=\(key) windowID=\(item.windowID) " +
                        "reason=native-reveal-unavailable section=\(address.section.logString)",
                    level: .warning
                )
                return true
            }
            guard let stableFrame = await waitForStableOneDriveItem(item, on: resolvedDisplayID) else {
                diagnosticLogger.write(
                    "OD_NATIVE_REVEAL_TIMEOUT key=\(key) windowID=\(item.windowID) " +
                        "targetDisplayID=\(resolvedDisplayID) \(liveBoundsDetails(for: item))",
                    level: .warning
                )
                finishOneDriveNativeReveal(reason: "item-stability-timeout")
                return true
            }
            expectedFrame = stableFrame
            diagnosticLogger.write(
                "OD_NATIVE_REVEAL_READY key=\(key) windowID=\(item.windowID) " +
                    "targetDisplayID=\(resolvedDisplayID) frame=\(NSStringFromRect(stableFrame))"
            )
        }

        let windowIDsBeforePress = Set(Bridging.getWindowList(option: .onScreen))
        diagnosticLogger.write(
            "AX_ACTIVATE_START key=\(key) windowID=\(item.windowID) sourcePID=\(sourcePID) " +
                "targetDisplayID=\(resolvedDisplayID) nativeReveal=\(didRevealNatively) " +
                "\(liveBoundsDetails(for: item))"
        )

        let attempt = await Task.detached(priority: .userInitiated) {
            Self.performAccessibilityPress(sourcePID: sourcePID, expectedFrame: expectedFrame)
        }.value

        let selectedIndex = attempt.selectedIndex.map(String.init) ?? "nil"
        let selectedFrame = attempt.selectedFrame.map(NSStringFromRect) ?? "nil"
        let errorCode = attempt.errorCode.map(String.init) ?? "nil"
        let details = "outcome=\(attempt.outcome.rawValue) candidates=\(attempt.candidateCount) " +
            "selectedIndex=\(selectedIndex) selectedFrame=\(selectedFrame) axError=\(errorCode)"

        if attempt.outcome != .pressed {
            diagnosticLogger.write(
                "AX_ACTIVATE_FALLBACK key=\(key) windowID=\(item.windowID) sourcePID=\(sourcePID) \(details)",
                level: .warning
            )
            if didRevealNatively {
                do {
                    try await postClickEvents(item: item, mouseButton: mouseButton)
                    diagnosticLogger.write(
                        "OD_NATIVE_REVEAL_HARDWARE_CLICK key=\(key) windowID=\(item.windowID)"
                    )
                } catch {
                    diagnosticLogger.write(
                        "OD_NATIVE_REVEAL_CLICK_FAILED key=\(key) windowID=\(item.windowID) " +
                            "error=\(String(describing: error))",
                        level: .error
                    )
                    finishOneDriveNativeReveal(reason: "click-failed")
                    return true
                }
            } else {
                return false
            }
        }

        if let interface = await waitForNewInterfaceWindow(
            ownerPID: sourcePID,
            excluding: windowIDsBeforePress
        ) {
            let interfaceBounds = interface.currentBounds() ?? interface.bounds
            let targetBounds = CGDisplayBounds(resolvedDisplayID)
            let interfaceCenter = CGPoint(x: interfaceBounds.midX, y: interfaceBounds.midY)
            let isOnTargetDisplay = targetBounds.contains(interfaceCenter)
            diagnosticLogger.write(
                "AX_ACTIVATE_VERIFIED key=\(key) windowID=\(item.windowID) sourcePID=\(sourcePID) " +
                "interfaceWindowID=\(interface.windowID) interfaceBounds=\(NSStringFromRect(interfaceBounds)) " +
                "targetDisplayID=\(resolvedDisplayID) onTargetDisplay=\(isOnTargetDisplay) \(details)",
                level: isOnTargetDisplay ? .info : .warning
            )
            if didRevealNatively {
                monitorOneDriveInterface(interface, key: key)
            }
        } else {
            // Do not immediately synthesize another click after an accepted
            // AXPress: a delayed OneDrive popup could turn that fallback into
            // a second click that closes the interface again.
            diagnosticLogger.write(
                "AX_ACTIVATE_UNVERIFIED key=\(key) windowID=\(item.windowID) sourcePID=\(sourcePID) \(details)",
                level: .warning
            )
            if didRevealNatively {
                finishOneDriveNativeReveal(reason: "interface-not-observed")
            }
        }
        return true
    }

    /// Returns the equivalent event subtypes for clicking a menu bar
    /// item with the given mouse button.
    private nonisolated func getClickSubtypes(
        for mouseButton: CGMouseButton
    ) -> (down: MenuBarItemEventType.ClickSubtype, up: MenuBarItemEventType.ClickSubtype) {
        switch mouseButton {
        case .left: (.leftMouseDown, .leftMouseUp)
        case .right: (.rightMouseDown, .rightMouseUp)
        default: (.otherMouseDown, .otherMouseUp)
        }
    }

    /// Creates and posts a series of events to click a menu bar item.
    ///
    /// - Parameters:
    ///   - item: The menu bar item to click.
    ///   - mouseButton: The mouse button to click the item with.
    private func postClickEvents(item: MenuBarItem, mouseButton: CGMouseButton) async throws {
        try await eventSemaphore.waitUnlessCancelled()
        defer {
            eventSemaphore.signal()
        }

        let clickPoint = try await getCurrentBounds(for: item).center
        let mouseLocation = try getMouseLocation()
        let source = try getEventSource()

        try permitLocalEvents()

        let clickTypes = getClickSubtypes(for: mouseButton)
        let timeout = Duration.milliseconds(250)

        guard
            let mouseDown = CGEvent.menuBarItemEvent(
                item: item,
                source: source,
                type: .click(clickTypes.down),
                location: clickPoint
            ),
            let mouseUp = CGEvent.menuBarItemEvent(
                item: item,
                source: source,
                type: .click(clickTypes.up),
                location: clickPoint
            )
        else {
            throw EventError.eventCreationFailure(item)
        }

        let cursorLease = MouseHelpers.hideCursor(owner: "click-events:\(item.tag)")
        defer {
            cursorLease.release {
                MouseHelpers.warpCursor(to: mouseLocation)
            }
        }

        do {
            try await postEventWithBarrier(
                mouseDown,
                to: item,
                timeout: timeout
            )
            try await postEventWithBarrier(
                mouseUp,
                to: item,
                timeout: timeout,
                repeating: 2 // Double mouse up prevents invalid item state.
            )
        } catch {
            do {
                logger.warning("Click events failed, posting fallback")
                try await postEventWithBarrier(
                    mouseUp,
                    to: item,
                    timeout: timeout,
                    repeating: 2 // Double mouse up prevents invalid item state.
                )
            } catch {
                // Catch this for logging purposes only. We want to propagate
                // the original error.
                logger.error("Fallback failed with error: \(error, privacy: .public)")
            }
            throw error
        }
    }

    /// Clicks a menu bar item with the given mouse button.
    ///
    /// - Parameters:
    ///   - item: The menu bar item to click.
    ///   - mouseButton: The mouse button to click the item with.
    func click(
        item: MenuBarItem,
        with mouseButton: CGMouseButton,
        on displayID: CGDirectDisplayID? = nil
    ) async throws {
        guard let appState else {
            throw EventError.cannotComplete
        }

        if await activateOneDriveWithAccessibilityIfPossible(
            item: item,
            mouseButton: mouseButton,
            targetDisplayID: displayID
        ) {
            return
        }

        try await waitForUserToPauseInput()

        logger.log(
            """
            Clicking \(item.logString, privacy: .public) with \
            \(mouseButton.logString, privacy: .public)
            """
        )

        appState.hidEventManager.stopAll()
        defer {
            appState.hidEventManager.startAll()
        }

        let maxAttempts = 4
        for n in 1...maxAttempts {
            guard !Task.isCancelled else {
                throw EventError.cannotComplete
            }
            do {
                try await postClickEvents(item: item, mouseButton: mouseButton)
                logger.debug("Attempt \(n, privacy: .public) succeeded, finished with click")
                return
            } catch {
                logger.debug("Attempt \(n, privacy: .public) failed: \(error, privacy: .public)")
                if n < maxAttempts {
                    await eventSleep()
                    continue
                }
                if error is EventError {
                    throw error
                }
                throw EventError.cannotComplete
            }
        }
    }
}

// MARK: - Temporarily Showing Items

extension MenuBarItemManager {
    /// Context for a temporarily shown menu bar item.
    private final class TemporarilyShownItemContext {
        /// The current window identifier for the item. This can change if the
        /// source app recreates its status item while its interface is open.
        private(set) var windowID: CGWindowID

        /// The tag associated with the item.
        let tag: MenuBarItemTag

        /// The source process, used to reconnect a recreated item to the
        /// correct context when several items share the same tag.
        let sourcePID: pid_t?

        /// The destination to return the item to.
        let returnDestination: MoveDestination

        /// The exact logical cache location before the item was shown. This
        /// breaks return-anchor cycles when two duplicate items are opened in
        /// succession and each uses the other as its nearest neighbor.
        let originalSection: MenuBarSection.Name
        let originalIndex: Int

        /// The window of the item's shown interface.
        var shownInterfaceWindow: WindowInfo?

        /// The number of attempts that have been made to rehide the item.
        var rehideAttempts = 0

        /// The number of rehide checks where the item window was absent.
        var missingItemAttempts = 0

        /// A Boolean value that indicates whether the menu bar item's
        /// interface is showing.
        var isShowingInterface: Bool {
            guard
                let window = shownInterfaceWindow,
                let current = WindowInfo(windowID: window.windowID)
            else {
                // Window no longer exists, so assume closed.
                return false
            }
            if
                current.layer != CGWindowLevelForKey(.popUpMenuWindow),
                current.layer != CGWindowLevelForKey(.popUpMenuWindow) - 1,
                current.layer != CGWindowLevelForKey(.statusWindow),
                current.layer != CGWindowLevelForKey(.mainMenuWindow),
                let app = current.owningApplication
            {
                return app.isActive && current.isOnScreen
            }
            return current.isOnScreen
        }

        init(
            item: MenuBarItem,
            returnDestination: MoveDestination,
            originalAddress: (section: MenuBarSection.Name, index: Int)
        ) {
            self.windowID = item.windowID
            self.tag = item.tag
            self.sourcePID = item.sourcePID
            self.returnDestination = returnDestination
            self.originalSection = originalAddress.section
            self.originalIndex = originalAddress.index
        }

        /// Returns whether the item belongs to this context. The live window
        /// identifier is authoritative. The source process plus tag is a safe
        /// fallback for apps that recreate a status window during a click.
        func matches(_ item: MenuBarItem) -> Bool {
            if item.windowID == windowID {
                return true
            }
            guard item.tag == tag, let sourcePID else {
                return false
            }
            return item.sourcePID == sourcePID
        }

        /// Updates the live identity after a recreated window is matched.
        func observe(_ item: MenuBarItem) {
            windowID = item.windowID
        }
    }

    /// Returns the one temporary-show context that matches the live item.
    /// Requiring an unambiguous match prevents one OneDrive account from
    /// borrowing the context of another account with the same tag.
    private func temporarilyShownContext(matching item: MenuBarItem) -> TemporarilyShownItemContext? {
        let allContexts = temporarilyShownItemContexts + rehidingItemContexts
        if let exact = allContexts.first(where: { $0.windowID == item.windowID }) {
            return exact
        }
        let candidates = allContexts.filter { $0.matches(item) }
        guard candidates.count == 1, let context = candidates.first else {
            return nil
        }
        context.observe(item)
        logTemporaryItemEvent("TEMP_SHOW_RECONNECTED", context: context, item: item)
        return context
    }

    /// Returns whether placement automation must leave this duplicate group
    /// alone while a temporarily shown item is being clicked or rehidden.
    func isTemporarilyShowingItem(withAutomationKey key: String) -> Bool {
        temporarilyShownItemContexts.contains { $0.tag.automationKey == key } ||
            rehidingItemContexts.contains { $0.tag.automationKey == key }
    }

    private func resumeAutomationIfNeeded(for key: String?) {
        guard
            let key,
            !isTemporarilyShowingItem(withAutomationKey: key)
        else {
            return
        }
        appState?.automationManager.resumeAfterTemporaryShow(forAutomationKey: key)
    }

    private func logTemporaryItemEvent(
        _ event: String,
        context: TemporarilyShownItemContext,
        item: MenuBarItem? = nil,
        details: String? = nil,
        level: AutomationDiagnosticLogger.Level = .info
    ) {
        let key = context.tag.automationKey?
            .replacingOccurrences(of: "\u{1F}", with: "|") ?? String(describing: context.tag)
        let liveWindowID = item?.windowID ?? context.windowID
        let sourcePID = (item?.sourcePID ?? context.sourcePID).map(String.init) ?? "nil"
        let suffix = details.map { " \($0)" } ?? ""
        diagnosticLogger.write(
            "\(event) key=\(key) windowID=\(liveWindowID) sourcePID=\(sourcePID)\(suffix)",
            level: level
        )
    }

    /// Captures the live physical position separately from Ice's logical item
    /// cache. This reveals whether an app moves its own status window as a
    /// side effect of receiving a synthetic click.
    private func liveBoundsDetails(for item: MenuBarItem) -> String {
        guard let bounds = Bridging.getWindowBounds(for: item.windowID) else {
            return "liveBounds=missing"
        }
        let minX = String(format: "%.1f", bounds.minX)
        let width = String(format: "%.1f", bounds.width)
        return "liveX=\(minX) liveWidth=\(width) onScreen=\(Bridging.isWindowOnScreen(item.windowID))"
    }

    /// Gets the destination to return the given item to after it is
    /// temporarily shown.
    private func getReturnDestination(
        for item: MenuBarItem,
        originalAddress: (section: MenuBarSection.Name, index: Int),
        in liveItems: [MenuBarItem]
    ) -> MoveDestination? {
        let sectionItems = itemCache.managedItems(for: originalAddress.section)
        let index = originalAddress.index
        guard
            sectionItems.indices.contains(index),
            sectionItems[index].windowID == item.windowID
        else {
            return nil
        }

        // Only use a logical neighbor from the item's original Ice section.
        // WindowServer's global ordering can place the nearest raw neighbor on
        // the other side of a section divider, which teaches AppKit a bad
        // preferred position when the item is returned.
        if sectionItems.indices.contains(index + 1) {
            return .leftOfItem(sectionItems[index + 1])
        }
        if sectionItems.indices.contains(index - 1) {
            return .rightOfItem(sectionItems[index - 1])
        }

        guard let hiddenControlItem = liveItems.first(matching: .hiddenControlItem) else {
            return nil
        }
        return switch originalAddress.section {
        case .visible:
            .rightOfItem(hiddenControlItem)
        case .hidden:
            .leftOfItem(hiddenControlItem)
        case .alwaysHidden:
            .leftOfItem(liveItems.first(matching: .alwaysHiddenControlItem) ?? hiddenControlItem)
        }
    }

    /// Resolves a possibly recreated item from a fresh menu bar item list.
    private func resolveCurrentItem(
        for context: TemporarilyShownItemContext,
        in items: [MenuBarItem]
    ) -> MenuBarItem? {
        if let exact = items.first(where: { $0.windowID == context.windowID }) {
            return exact
        }
        let candidates = items.filter(context.matches)
        guard candidates.count == 1, let item = candidates.first else {
            return nil
        }
        context.observe(item)
        logTemporaryItemEvent("TEMP_SHOW_RECONNECTED", context: context, item: item)
        return item
    }

    /// Refreshes the destination target from the current window list. This is
    /// needed when a neighboring status item is recreated while the interface
    /// is open, and also keeps duplicate tags from resolving to the wrong item.
    private func resolveCurrentDestination(
        _ destination: MoveDestination,
        in items: [MenuBarItem]
    ) -> MoveDestination? {
        let oldTarget = destination.targetItem
        let target: MenuBarItem?

        if oldTarget.tag.isControlItem {
            target = items.first(matching: oldTarget.tag)
        } else if let exact = items.first(where: { $0.windowID == oldTarget.windowID }) {
            target = exact
        } else {
            let candidates = items.filter { item in
                guard item.tag == oldTarget.tag else {
                    return false
                }
                guard let sourcePID = oldTarget.sourcePID else {
                    return true
                }
                return item.sourcePID == sourcePID
            }
            target = candidates.count == 1 ? candidates.first : nil
        }

        guard let target else {
            return nil
        }
        return switch destination {
        case .leftOfItem: .leftOfItem(target)
        case .rightOfItem: .rightOfItem(target)
        }
    }

    /// Resolves a safe destination for a rehide operation. If the original
    /// neighbor is also temporarily shown, using it would create a circular
    /// dependency and leave both items in the visible section. In that case,
    /// return directly through the original section's control item.
    private func resolveRehideDestination(
        for context: TemporarilyShownItemContext,
        in items: [MenuBarItem]
    ) -> (destination: MoveDestination, usedSectionFallback: Bool)? {
        let allContexts = temporarilyShownItemContexts + rehidingItemContexts
        let targetWindowID = context.returnDestination.targetItem.windowID
        let targetIsTemporary = allContexts.contains { other in
            other !== context && other.windowID == targetWindowID
        }

        let targetIsInOriginalSection = itemCache
            .address(forWindowID: context.returnDestination.targetItem.windowID)?
            .section == context.originalSection
        let targetIsSectionControl = context.returnDestination.targetItem.tag.isControlItem

        if !targetIsTemporary,
           targetIsInOriginalSection || targetIsSectionControl,
           let destination = resolveCurrentDestination(context.returnDestination, in: items) {
            return (destination, false)
        }

        guard let hiddenControlItem = items.first(matching: .hiddenControlItem) else {
            return nil
        }
        let destination: MoveDestination = switch context.originalSection {
        case .visible:
            .rightOfItem(hiddenControlItem)
        case .hidden:
            .leftOfItem(hiddenControlItem)
        case .alwaysHidden:
            .leftOfItem(items.first(matching: .alwaysHiddenControlItem) ?? hiddenControlItem)
        }
        return (destination, true)
    }

    /// Schedules a timer for the given interval that rehides the
    /// temporarily shown items when fired.
    private func runRehideTimer(for interval: TimeInterval? = nil) {
        guard let appState else {
            return
        }
        let interval = interval ?? appState.settings.advanced.tempShowInterval
        logger.debug("Running rehide timer for interval: \(interval, format: .fixed, privacy: .public)")
        rehideTimer?.invalidate()
        rehideTimer = .scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            logger.debug("Rehide timer fired")
            Task {
                await self.rehideTemporarilyShownItems()
            }
        }
    }

    /// Temporarily shows the given item.
    ///
    /// The item is cached and returned to its original location after the
    /// time interval specified by ``AdvancedSettings/tempShowInterval``.
    ///
    /// - Parameters:
    ///   - item: The item to temporarily show.
    ///   - mouseButton: The mouse button to click the item with.
    func temporarilyShow(
        item: MenuBarItem,
        clickingWith mouseButton: CGMouseButton,
        on displayID: CGDirectDisplayID? = nil
    ) async {
        guard let appState else {
            logger.error("Missing AppState, so not showing \(item.logString, privacy: .public)")
            return
        }

        if await activateOneDriveWithAccessibilityIfPossible(
            item: item,
            mouseButton: mouseButton,
            targetDisplayID: displayID
        ) {
            return
        }

        let requestedScreen = displayID.flatMap { requestedDisplayID in
            NSScreen.screens.first { $0.displayID == requestedDisplayID }
        }
        guard let screen = requestedScreen ?? NSScreen.screenWithActiveMenuBar else {
            logger.error("No active menu bar screen, so not showing \(item.logString, privacy: .public)")
            return
        }

        guard let applicationMenuFrame = screen.getApplicationMenuFrame() else {
            logger.error("No application menu frame, so not showing \(item.logString, privacy: .public)")
            return
        }

        guard let originalAddress = itemCache.address(forWindowID: item.windowID) else {
            logger.error("No original cache address for \(item.logString, privacy: .public)")
            return
        }

        var items = await MenuBarItem.getMenuBarItems(option: .activeSpace)

        guard let destination = getReturnDestination(
            for: item,
            originalAddress: originalAddress,
            in: items
        ) else {
            logger.error("No return destination for \(item.logString, privacy: .public)")
            return
        }

        // Remove all items up to and including the hidden control item.
        if let index = items.firstIndex(matching: .hiddenControlItem) {
            items.removeSubrange(...index)
        }

        let maxX: CGFloat = {
            var maxX = applicationMenuFrame.maxX
            if let frameOfNotch = screen.frameOfNotch {
                maxX = max(maxX, frameOfNotch.maxX + 30)
            }
            return maxX + item.bounds.width
        }()

        // Remove items until we have enough room to show this item.
        items.trimPrefix { item in
            if item.isOnScreen && item.canBeHidden {
                return item.bounds.minX <= maxX
            }
            return true
        }

        guard let targetItem = items.first else {
            logger.warning("Not enough room to show \(item.logString, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "Not enough room to show \"\(item.displayName)\""
            alert.runModal()
            return
        }

        appState.hidEventManager.stopAll()
        defer {
            appState.hidEventManager.startAll()
        }

        let context = TemporarilyShownItemContext(
            item: item,
            returnDestination: destination,
            originalAddress: originalAddress
        )
        temporarilyShownItemContexts.removeAll { $0.windowID == item.windowID }
        rehidingItemContexts.removeAll { $0.windowID == item.windowID }
        temporarilyShownItemContexts.append(context)

        logger.debug("Temporarily showing \(item.logString, privacy: .public)")
        logTemporaryItemEvent(
            "TEMP_SHOW_START",
            context: context,
            item: item,
            details: "returnTargetWindowID=\(destination.targetItem.windowID)"
        )

        do {
            try await move(item: item, to: .leftOfItem(targetItem))
        } catch {
            logger.error("Error showing item: \(error, privacy: .public)")
            temporarilyShownItemContexts.removeAll { $0 === context }
            logTemporaryItemEvent(
                "TEMP_SHOW_MOVE_FAILURE",
                context: context,
                item: item,
                details: "error=\(String(describing: error))",
                level: .error
            )
            resumeAutomationIfNeeded(for: context.tag.automationKey)
            return
        }
        logTemporaryItemEvent(
            "TEMP_SHOW_MOVED",
            context: context,
            item: item,
            details: liveBoundsDetails(for: item)
        )

        rehideTimer?.invalidate()
        defer {
            runRehideTimer()
        }

        await eventSleep(for: .milliseconds(100))
        let idsBeforeClick = Set(Bridging.getWindowList(option: .onScreen))

        do {
            try await click(item: item, with: mouseButton, on: displayID)
        } catch {
            logger.error("Error clicking item: \(error, privacy: .public)")
            logTemporaryItemEvent(
                "TEMP_SHOW_CLICK_FAILURE",
                context: context,
                item: item,
                details: "error=\(String(describing: error))",
                level: .error
            )
            return
        }
        logTemporaryItemEvent(
            "TEMP_SHOW_CLICKED",
            context: context,
            item: item,
            details: liveBoundsDetails(for: item)
        )

        await eventSleep(for: .milliseconds(250))
        let windowsAfterClick = WindowInfo.createWindows(option: .onScreen)

        context.shownInterfaceWindow = windowsAfterClick.first { window in
            window.ownerPID == item.sourcePID && !idsBeforeClick.contains(window.windowID)
        }
        let interfaceWindowID = context.shownInterfaceWindow.map { String($0.windowID) } ?? "nil"
        logTemporaryItemEvent(
            "TEMP_SHOW_INTERFACE",
            context: context,
            item: item,
            details: "interfaceWindowID=\(interfaceWindowID) \(liveBoundsDetails(for: item))"
        )
    }

    /// Rehides all temporarily shown items.
    ///
    /// If an item is currently showing its interface, this method waits
    /// for the interface to close before hiding the items.
    func rehideTemporarilyShownItems() async {
        guard let appState else {
            logger.error("Missing AppState, so not rehiding")
            return
        }
        guard !temporarilyShownItemContexts.isEmpty else {
            return
        }
        guard !isRehidingTemporaryItems else {
            return
        }
        guard !temporarilyShownItemContexts.contains(where: { $0.isShowingInterface }) else {
            logger.debug("Menu bar item interface is shown, so waiting to rehide")
            runRehideTimer(for: 3)
            return
        }
        guard hasUserPausedInput(for: .milliseconds(250)) else {
            logger.debug("Found recent user input, so waiting to rehide")
            runRehideTimer(for: 1)
            return
        }

        isRehidingTemporaryItems = true
        defer {
            isRehidingTemporaryItems = false
        }

        var currentContexts = temporarilyShownItemContexts
        let automationKeysBeforeRehide = Set(currentContexts.compactMap { $0.tag.automationKey })
        temporarilyShownItemContexts.removeAll()
        rehidingItemContexts = currentContexts

        let items = await MenuBarItem.getMenuBarItems(option: .activeSpace)
        var failedContexts = [TemporarilyShownItemContext]()

        appState.hidEventManager.stopAll()
        defer {
            appState.hidEventManager.startAll()
        }

        await eventSleep(for: .milliseconds(250))

        logger.debug("Rehiding temporarily shown items")

        while let context = currentContexts.popLast() {
            guard let item = resolveCurrentItem(for: context, in: items) else {
                context.missingItemAttempts += 1
                if context.missingItemAttempts < 20 {
                    failedContexts.append(context)
                    logTemporaryItemEvent(
                        "TEMP_REHIDE_WAITING",
                        context: context,
                        details: "reason=item-missing attempt=\(context.missingItemAttempts)",
                        level: .warning
                    )
                } else {
                    logTemporaryItemEvent(
                        "TEMP_REHIDE_EXPIRED",
                        context: context,
                        details: "reason=item-missing attempts=\(context.missingItemAttempts)",
                        level: .warning
                    )
                }
                continue
            }
            context.missingItemAttempts = 0
            guard let resolvedDestination = resolveRehideDestination(for: context, in: items) else {
                context.rehideAttempts += 1
                failedContexts.append(context)
                logTemporaryItemEvent(
                    "TEMP_REHIDE_WAITING",
                    context: context,
                    item: item,
                    details: "reason=destination-missing attempt=\(context.rehideAttempts)",
                    level: .warning
                )
                continue
            }
            if resolvedDestination.usedSectionFallback {
                logTemporaryItemEvent(
                    "TEMP_REHIDE_FALLBACK",
                    context: context,
                    item: item,
                    details: "section=\(context.originalSection.logString) reason=temporary-anchor",
                    level: .warning
                )
            }
            do {
                try await move(item: item, to: resolvedDestination.destination)
                logTemporaryItemEvent("TEMP_REHIDE_SUCCESS", context: context, item: item)
            } catch {
                context.rehideAttempts += 1
                logger.warning(
                    """
                    Attempt \(context.rehideAttempts, privacy: .public) to rehide \
                    \(item.logString, privacy: .public) failed with error: \
                    \(error, privacy: .public)
                    """
                )
                if context.rehideAttempts < 3 {
                    currentContexts.append(context) // Try again.
                } else {
                    // Failed contexts are ultimately added back to the array
                    // and rehidden after a longer delay, so reset the count.
                    context.rehideAttempts = 0
                    failedContexts.append(context)
                }
                logTemporaryItemEvent(
                    "TEMP_REHIDE_FAILURE",
                    context: context,
                    item: item,
                    details: "attempt=\(context.rehideAttempts) error=\(String(describing: error))",
                    level: .warning
                )
            }
        }

        if failedContexts.isEmpty {
            logger.debug("All items were successfully rehidden")
        } else {
            logger.error(
                """
                Some items failed to rehide: \
                \(failedContexts.map { $0.tag }, privacy: .public)
                """
            )
        }

        rehidingItemContexts.removeAll()
        temporarilyShownItemContexts.append(contentsOf: failedContexts.reversed())
        if !failedContexts.isEmpty {
            runRehideTimer(for: 3)
        }

        for key in automationKeysBeforeRehide {
            resumeAutomationIfNeeded(for: key)
        }
    }

    /// Removes a temporarily shown item from the cache, ensuring that
    /// the item is _not_ returned to its original location.
    func removeTemporarilyShownItemFromCache(withWindowID windowID: CGWindowID) {
        var removedAutomationKeys = Set<String>()
        while let index = temporarilyShownItemContexts.firstIndex(where: { $0.windowID == windowID }) {
            let context = temporarilyShownItemContexts[index]
            if let key = context.tag.automationKey {
                removedAutomationKeys.insert(key)
            }
            logger.debug(
                """
                Removing temporarily shown item from cache: \
                \(context.tag, privacy: .public)
                """
            )
            logTemporaryItemEvent(
                "TEMP_SHOW_CONTEXT_REMOVED",
                context: context,
                details: "reason=manual-move"
            )
            temporarilyShownItemContexts.remove(at: index)
        }
        while let index = rehidingItemContexts.firstIndex(where: { $0.windowID == windowID }) {
            let context = rehidingItemContexts[index]
            if let key = context.tag.automationKey {
                removedAutomationKeys.insert(key)
            }
            logTemporaryItemEvent(
                "TEMP_SHOW_CONTEXT_REMOVED",
                context: context,
                details: "reason=manual-move-during-rehide"
            )
            rehidingItemContexts.remove(at: index)
        }
        for key in removedAutomationKeys {
            resumeAutomationIfNeeded(for: key)
        }
    }
}

// MARK: - Control Item Order

extension MenuBarItemManager {
    /// Enforces the order of the given control items, ensuring that the
    /// control item for the always-hidden section is positioned to the
    /// left of control item for the hidden section.
    private func enforceControlItemOrder(controlItems: ControlItemPair) async {
        let hidden = controlItems.hidden

        guard
            let alwaysHidden = controlItems.alwaysHidden,
            hidden.bounds.maxX <= alwaysHidden.bounds.minX
        else {
            return
        }

        do {
            logger.debug("Control items have incorrect order")
            try await move(item: alwaysHidden, to: .leftOfItem(hidden))
        } catch {
            logger.error("Error enforcing control item order: \(error, privacy: .public)")
        }
    }
}

// MARK: - MenuBarItemEventType

/// Event types for menu bar item events.
private enum MenuBarItemEventType {
    /// The event type for moving a menu bar item.
    case move(MoveSubtype)
    /// The event type for clicking a menu bar item.
    case click(ClickSubtype)

    var cgEventType: CGEventType {
        switch self {
        case .move(let subtype): subtype.cgEventType
        case .click(let subtype): subtype.cgEventType
        }
    }

    var cgEventFlags: CGEventFlags {
        switch self {
        case .move(.mouseDown): .maskCommand
        case .move, .click: []
        }
    }

    var cgMouseButton: CGMouseButton {
        switch self {
        case .move: .left
        case .click(let subtype): subtype.cgMouseButton
        }
    }

    // MARK: Subtypes

    /// Subtype for menu bar item move events.
    enum MoveSubtype {
        case mouseDown
        case mouseUp

        var cgEventType: CGEventType {
            switch self {
            case .mouseDown: .leftMouseDown
            case .mouseUp: .leftMouseUp
            }
        }
    }

    /// Subtype for menu bar item click events.
    enum ClickSubtype {
        case leftMouseDown
        case leftMouseUp
        case rightMouseDown
        case rightMouseUp
        case otherMouseDown
        case otherMouseUp

        var cgEventType: CGEventType {
            switch self {
            case .leftMouseDown: .leftMouseDown
            case .leftMouseUp: .leftMouseUp
            case .rightMouseDown: .rightMouseDown
            case .rightMouseUp: .rightMouseUp
            case .otherMouseDown: .otherMouseDown
            case .otherMouseUp: .otherMouseUp
            }
        }

        var cgMouseButton: CGMouseButton {
            switch self {
            case .leftMouseDown, .leftMouseUp: .left
            case .rightMouseDown, .rightMouseUp: .right
            case .otherMouseDown, .otherMouseUp: .center
            }
        }

        var clickState: Int64 {
            switch self {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown: 1
            case .leftMouseUp, .rightMouseUp, .otherMouseUp: 0
            }
        }
    }
}

// MARK: - CGEventField Helpers

private extension CGEventField {
    /// Key to access a field that contains the event's window identifier.
    static let windowID = CGEventField(rawValue: 0x33)! // swiftlint:disable:this force_unwrapping

    /// Fields that can be used to compare menu bar item events.
    static let menuBarItemEventFields: [CGEventField] = [
        .eventSourceUserData,
        .mouseEventWindowUnderMousePointer,
        .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
        .windowID,
    ]
}

// MARK: - CGEventFilterMask Helpers

private extension CGEventFilterMask {
    /// Specifies that all events should be permitted during event suppression states.
    static let permitAllEvents: CGEventFilterMask = [
        .permitLocalMouseEvents,
        .permitLocalKeyboardEvents,
        .permitSystemDefinedEvents,
    ]
}

// MARK: - CGEventType Helpers

private extension CGEventType {
    /// A string to use for logging purposes.
    var logString: String {
        switch self {
        case .null: "null event"
        case .leftMouseDown: "leftMouseDown event"
        case .leftMouseUp: "leftMouseUp event"
        case .rightMouseDown: "rightMouseDown event"
        case .rightMouseUp: "rightMouseUp event"
        case .mouseMoved: "mouseMoved event"
        case .leftMouseDragged: "leftMouseDragged event"
        case .rightMouseDragged: "rightMouseDragged event"
        case .keyDown: "keyDown event"
        case .keyUp: "keyUp event"
        case .flagsChanged: "flagsChanged event"
        case .scrollWheel: "scrollWheel event"
        case .tabletPointer: "tabletPointer event"
        case .tabletProximity: "tabletProximity event"
        case .otherMouseDown: "otherMouseDown event"
        case .otherMouseUp: "otherMouseUp event"
        case .otherMouseDragged: "otherMouseDragged event"
        case .tapDisabledByTimeout: "tapDisabledByTimeout event"
        case .tapDisabledByUserInput: "tapDisabledByUserInput event"
        @unknown default: "unknown event"
        }
    }
}

// MARK: - CGMouseButton Helpers

private extension CGMouseButton {
    /// A string to use for logging purposes.
    var logString: String {
        switch self {
        case .left: "left mouse button"
        case .right: "right mouse button"
        case .center: "center mouse button"
        @unknown default: "unknown mouse button"
        }
    }
}

// MARK: - CGEvent Helpers

private extension CGEvent {
    /// Returns an event that can be sent to a menu bar item.
    ///
    /// - Parameters:
    ///   - item: The event's target item.
    ///   - source: The event's source.
    ///   - type: The event's specialized type.
    ///   - location: The event's location. Does not need to be
    ///     within the bounds of the item.
    static func menuBarItemEvent(
        item: MenuBarItem,
        source: CGEventSource,
        type: MenuBarItemEventType,
        location: CGPoint
    ) -> CGEvent? {
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type.cgEventType,
            mouseCursorPosition: location,
            mouseButton: type.cgMouseButton
        ) else {
            return nil
        }
        event.setFlags(for: type)
        event.setUserData(ObjectIdentifier(event))
        event.setWindowID(item.windowID, for: type)
        event.setClickState(for: type)
        return event
    }

    /// Returns a null event with unique user data.
    static func uniqueNullEvent() -> CGEvent? {
        guard let event = CGEvent(source: nil) else {
            return nil
        }
        event.setUserData(ObjectIdentifier(event))
        return event
    }

    /// Posts the event to the given event tap location.
    ///
    /// - Parameter location: The event tap location to post the event to.
    func post(to location: EventTap.Location) {
        let type = self.type
        Logger.menuBarItemManager.debug(
            """
            Posting \(type.logString, privacy: .public) \
            to \(location.logString, privacy: .public)
            """
        )
        switch location {
        case .hidEventTap: post(tap: .cghidEventTap)
        case .sessionEventTap: post(tap: .cgSessionEventTap)
        case .annotatedSessionEventTap: post(tap: .cgAnnotatedSessionEventTap)
        case .pid(let pid): postToPid(pid)
        }
    }

    /// Returns a Boolean value that indicates whether the given integer
    /// fields from this event are equivalent to the same integer fields
    /// from the specified event.
    ///
    /// - Parameters:
    ///   - other: The event to compare with this event.
    ///   - fields: The integer fields to check.
    func matches(_ other: CGEvent, byIntegerFields fields: [CGEventField]) -> Bool {
        fields.allSatisfy { field in
            getIntegerValueField(field) == other.getIntegerValueField(field)
        }
    }

    func setTargetPID(_ pid: pid_t) {
        let targetPID = Int64(pid)
        setIntegerValueField(.eventTargetUnixProcessID, value: targetPID)
    }

    private func setFlags(for type: MenuBarItemEventType) {
        flags = type.cgEventFlags
    }

    private func setUserData(_ bitPattern: ObjectIdentifier) {
        let userData = Int64(Int(bitPattern: bitPattern))
        setIntegerValueField(.eventSourceUserData, value: userData)
    }

    private func setWindowID(_ windowID: CGWindowID, for type: MenuBarItemEventType) {
        let windowID = Int64(windowID)

        setIntegerValueField(.mouseEventWindowUnderMousePointer, value: windowID)
        setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: windowID)

        if case .move = type {
            setIntegerValueField(.windowID, value: windowID)
        }
    }

    private func setClickState(for type: MenuBarItemEventType) {
        if case .click(let subtype) = type {
            setIntegerValueField(.mouseEventClickState, value: subtype.clickState)
        }
    }
}

// MARK: - Logger Helpers

private extension Logger {
    /// Logger for the menu bar item manager.
    static let menuBarItemManager = Logger(category: "MenuBarItemManager")
}
