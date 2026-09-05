import XCTest
@testable import Ice

final class TemporaryRehideRetryTests: XCTestCase {
    func testFreshInteractionCanRunImmediately() {
        XCTAssertEqual(TemporaryRehideRetryState().delayUntilRetry(now: 100), 0)
    }

    func testFailuresBackOffAndHaveOneLifetimeBudget() {
        var state = TemporaryRehideRetryState()
        for (index, delay) in [3.0, 6, 12, 24, 30].enumerated() {
            XCTAssertEqual(state.recordFailure(now: 100), delay)
            XCTAssertEqual(state.failureCount, index + 1)
            XCTAssertEqual(state.delayUntilRetry(now: 101), delay - 1)
            XCTAssertEqual(state.delayUntilRetry(now: 100 + delay), 0)
        }
        XCTAssertNil(state.recordFailure(now: 1_000))
        XCTAssertTrue(state.isSuspended)
        XCTAssertNil(state.delayUntilRetry(now: 1_000_000))
        XCTAssertNil(state.recordFailure(now: 1_000_000))
        XCTAssertEqual(state.failureCount, 6)
    }

    func testTimerReadsDoNotResetBudgetOrShortenCooldown() {
        var state = TemporaryRehideRetryState()
        state.recordFailure(now: 100)
        for _ in 0..<100 {
            XCTAssertEqual(state.delayUntilRetry(now: 101), 2)
        }
        XCTAssertEqual(state.failureCount, 1)
        XCTAssertEqual(state.recordFailure(now: 103), 6)
    }

    func testExplicitNewInteractionGetsANewBudget() {
        var oldInteraction = TemporaryRehideRetryState()
        for _ in 0..<6 { oldInteraction.recordFailure(now: 100) }
        XCTAssertTrue(oldInteraction.isSuspended)
        let newInteraction = TemporaryRehideRetryState()
        XCTAssertFalse(newInteraction.isSuspended)
        XCTAssertEqual(newInteraction.failureCount, 0)
    }

    @MainActor
    func testQueuedRequestRejectsNewLayoutGenerationBeforeContextRemoval() async {
        let originalGeneration: UInt64 = 4
        var currentGeneration = originalGeneration
        let contextStillOwned = true // Manual move's caller has not removed it yet.
        let request = MenuBarMoveRequest(isValid: {
            currentGeneration == originalGeneration && contextStillOwned
        })
        let queued = expectation(description: "request waits for move slot")
        let finished = expectation(description: "superseded request exits")
        var releaseMoveSlot: CheckedContinuation<Void, Never>?
        var gesturesSent = 0

        let task = Task {
            await withCheckedContinuation { continuation in
                releaseMoveSlot = continuation
                queued.fulfill()
            }
            do {
                try request.checkValidity()
                gesturesSent += 1
                XCTFail("A queued request must recheck the current layout generation")
            } catch {
                XCTAssertTrue(error is MenuBarMoveRequest.Invalidated)
            }
            finished.fulfill()
        }
        defer {
            releaseMoveSlot?.resume()
            task.cancel()
        }
        await fulfillment(of: [queued], timeout: 1)
        currentGeneration += 2 // A manual move began and finished while queued.
        releaseMoveSlot?.resume()
        releaseMoveSlot = nil
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertEqual(gesturesSent, 0)
    }

    @MainActor
    func testContextRemovalAndNativeRevealInvalidateExistingRequest() throws {
        var ownsContext = true
        var nativeRevealActive = false
        let request = MenuBarMoveRequest(isValid: { ownsContext && !nativeRevealActive })
        try request.checkValidity()

        nativeRevealActive = true
        XCTAssertThrowsError(try request.checkValidity()) { error in
            XCTAssertTrue(error is MenuBarMoveRequest.Invalidated)
        }
        nativeRevealActive = false
        ownsContext = false
        XCTAssertThrowsError(try request.checkValidity()) { error in
            XCTAssertTrue(error is MenuBarMoveRequest.Invalidated)
        }
    }

    @MainActor
    func testTaskCancellationRemainsDistinctFromMoveFailure() async {
        let request = MenuBarMoveRequest(isValid: { true })
        let finished = expectation(description: "cancelled request exits")
        let task = Task {
            do {
                try request.checkValidity()
                XCTFail("Cancelled requests must not start a gesture")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            finished.fulfill()
        }
        task.cancel()
        await fulfillment(of: [finished], timeout: 1)
    }

    @MainActor
    func testRehideUsesOneGestureWithoutChangingExistingMoveBudgets() {
        let normal = MenuBarMoveRequest(isValid: nil)
        XCTAssertEqual(normal.attemptLimit(default: 8), 8)
        XCTAssertEqual(normal.attemptLimit(default: 3), 3)
        let rehide = MenuBarMoveRequest(isValid: { true }, maximumAttempts: 1)
        XCTAssertEqual(rehide.attemptLimit(default: 8), 1)
        XCTAssertEqual(rehide.attemptLimit(default: 3), 1)
    }

    func testEitherMacOS26SourceOrWindowHostTerminationEndsInteraction() {
        let owner = TemporaryRehideOwner(sourcePID: 42, windowOwnerPID: 7)
        XCTAssertTrue(owner.wasTerminated(42))
        XCTAssertTrue(owner.wasTerminated(7))
        XCTAssertFalse(owner.wasTerminated(99))

        let unknownSource = TemporaryRehideOwner(sourcePID: nil, windowOwnerPID: 7)
        XCTAssertFalse(unknownSource.wasTerminated(42))
        XCTAssertTrue(unknownSource.wasTerminated(7))
    }

    func testRetiredWindowExcludesOldSnapshotButNotReplacementProcess() {
        let retiredOwner = TemporaryRehideOwner(sourcePID: 42, windowOwnerPID: 7)
        XCTAssertTrue(retiredOwner.matches(sourcePID: 42, windowOwnerPID: 7))
        XCTAssertTrue(retiredOwner.matches(sourcePID: nil, windowOwnerPID: 7))
        XCTAssertFalse(retiredOwner.matches(sourcePID: 43, windowOwnerPID: 7))
        XCTAssertFalse(retiredOwner.matches(sourcePID: 42, windowOwnerPID: 8))
    }

    func testNewClickTimerSurvivesOlderPassCompletion() {
        // The only pending context may belong to a new click: no old failure
        // is required for its configured temporary-show delay to be preserved.
        XCTAssertEqual(
            TemporaryRehideTimerAction.decide(pendingDelays: [0], hasValidTimer: true),
            .keepExisting
        )
        XCTAssertEqual(
            TemporaryRehideTimerAction.decide(pendingDelays: [0, 30], hasValidTimer: true),
            .keepExisting
        )
    }

    func testRetryTimerStopsWhenAllContextsAreSuspended() {
        XCTAssertEqual(
            TemporaryRehideTimerAction.decide(pendingDelays: [], hasValidTimer: false),
            .stop
        )
        XCTAssertEqual(
            TemporaryRehideTimerAction.decide(pendingDelays: [], hasValidTimer: true),
            .stop
        )
        XCTAssertEqual(
            TemporaryRehideTimerAction.decide(pendingDelays: [0, 30], hasValidTimer: false),
            .schedule(3)
        )
        XCTAssertEqual(
            TemporaryRehideTimerAction.decide(pendingDelays: [24, 30], hasValidTimer: false),
            .schedule(24)
        )
    }
}
