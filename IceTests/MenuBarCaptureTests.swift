//
//  MenuBarCaptureTests.swift
//  IceTests
//

import XCTest
@testable import Ice

@MainActor
final class MenuBarCaptureTests: XCTestCase {
    /// A capture API that deliberately ignores cancellation until released.
    /// This models the system completing an already-started screenshot request.
    private final class CaptureProbe {
        var sections = [Set<Int>]()
        var generations = [UInt64]()
        var cancelledCompletions = [Bool]()
        var activeCount = 0
        var maximumActiveCount = 0
        private var completions = [CheckedContinuation<Void, Never>]()

        func capture(_ sections: Set<Int>, generation: UInt64) async {
            self.sections.append(sections)
            generations.append(generation)
            activeCount += 1
            maximumActiveCount = max(maximumActiveCount, activeCount)
            await withCheckedContinuation { completions.append($0) }
            cancelledCompletions.append(Task.isCancelled)
            activeCount -= 1
        }

        func finishNext() {
            completions.removeFirst().resume()
        }
    }

    private func waitUntil(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Capture state did not settle", file: file, line: line)
                throw TaskTimeoutError()
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    func testConcurrentRequestsShareOneCapture() async throws {
        let probe = CaptureProbe()
        let coordinator = MenuBarCaptureCoordinator<Int>(operation: probe.capture)
        let first = Task { await coordinator.request([1]) }
        try await waitUntil { probe.activeCount == 1 }
        let others = (0..<9).map { _ in Task { await coordinator.request([1]) } }
        try await waitUntil { coordinator.pendingRequestCount == 10 }

        XCTAssertEqual(probe.sections, [[1]])
        probe.finishNext()
        await first.value
        for other in others { await other.value }

        XCTAssertEqual(probe.maximumActiveCount, 1)
        XCTAssertEqual(probe.sections.count, 1)
        XCTAssertEqual(coordinator.pendingRequestCount, 0)
    }

    func testPendingSectionsAreMergedWithoutRecapturingCompletedSections() async throws {
        let probe = CaptureProbe()
        let coordinator = MenuBarCaptureCoordinator<Int>(operation: probe.capture)
        let first = Task { await coordinator.request([1]) }
        try await waitUntil { probe.activeCount == 1 }
        let second = Task { await coordinator.request([1, 2]) }
        let third = Task { await coordinator.request([2, 3]) }
        try await waitUntil { coordinator.pendingRequestCount == 3 }

        probe.finishNext()
        await first.value
        try await waitUntil { probe.sections.count == 2 }
        XCTAssertEqual(probe.sections, [[1], [2, 3]])
        XCTAssertEqual(probe.maximumActiveCount, 1)

        probe.finishNext()
        await second.value
        await third.value
        XCTAssertEqual(coordinator.pendingRequestCount, 0)
    }

    func testInvalidationWaitsForOldAPIAndRestartsWithFreshGeneration() async throws {
        let probe = CaptureProbe()
        let coordinator = MenuBarCaptureCoordinator<Int>(operation: probe.capture)
        let caller = Task { await coordinator.request([1]) }
        try await waitUntil { probe.activeCount == 1 }

        coordinator.invalidate(reason: "test-display-change")
        XCTAssertEqual(probe.sections.count, 1)
        XCTAssertEqual(coordinator.pendingRequestCount, 1)
        probe.finishNext()

        try await waitUntil { probe.sections.count == 2 }
        XCTAssertEqual(probe.cancelledCompletions, [true])
        XCTAssertEqual(probe.generations, [0, 1])
        XCTAssertEqual(probe.maximumActiveCount, 1)
        XCTAssertEqual(coordinator.pendingRequestCount, 1)

        probe.finishNext()
        await caller.value
        XCTAssertEqual(probe.cancelledCompletions, [true, false])
    }

    func testCancellingOneCallerDoesNotCancelSharedCapture() async throws {
        let probe = CaptureProbe()
        let coordinator = MenuBarCaptureCoordinator<Int>(operation: probe.capture)
        var cancelledCallerReturned = false
        let first = Task {
            await coordinator.request([1])
            cancelledCallerReturned = true
        }
        try await waitUntil { probe.activeCount == 1 }
        let second = Task { await coordinator.request([1]) }
        try await waitUntil { coordinator.pendingRequestCount == 2 }

        first.cancel()
        try await waitUntil { cancelledCallerReturned }
        XCTAssertEqual(coordinator.pendingRequestCount, 1)
        XCTAssertEqual(probe.activeCount, 1)

        probe.finishNext()
        await second.value
        XCTAssertEqual(probe.cancelledCompletions, [false])
    }

    func testInvalidatingPartialRequestRecapturesAllOfItsSections() async throws {
        let probe = CaptureProbe()
        let coordinator = MenuBarCaptureCoordinator<Int>(operation: probe.capture)
        let first = Task { await coordinator.request([1]) }
        try await waitUntil { probe.activeCount == 1 }
        let combined = Task { await coordinator.request([1, 2]) }
        try await waitUntil { coordinator.pendingRequestCount == 2 }

        probe.finishNext()
        await first.value
        try await waitUntil { probe.sections.count == 2 }
        XCTAssertEqual(probe.sections, [[1], [2]])

        coordinator.invalidate(reason: "test-layout-change")
        probe.finishNext()
        try await waitUntil { probe.sections.count == 3 }
        XCTAssertEqual(probe.sections, [[1], [2], [1, 2]])
        XCTAssertEqual(probe.generations, [0, 0, 1])
        XCTAssertEqual(probe.maximumActiveCount, 1)

        probe.finishNext()
        await combined.value
    }

    func testTimeoutReturnsWithoutStartingAnOverlappingCapture() async throws {
        let probe = CaptureProbe()
        let coordinator = MenuBarCaptureCoordinator<Int>(operation: probe.capture)
        let timedCaller = Task(timeout: .milliseconds(20)) {
            await coordinator.request([1])
        }
        try await waitUntil { probe.activeCount == 1 }
        var timeoutReturned = false
        let observer = Task {
            do {
                try await timedCaller.value
                XCTFail("Expected the caller's timeout")
            } catch is TaskTimeoutError {
                timeoutReturned = true
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        try await waitUntil { timeoutReturned }
        await observer.value
        XCTAssertEqual(coordinator.pendingRequestCount, 0)

        let next = Task { await coordinator.request([1]) }
        try await waitUntil { coordinator.pendingRequestCount == 1 }
        XCTAssertEqual(probe.sections.count, 1)
        probe.finishNext()
        try await waitUntil { probe.sections.count == 2 }
        XCTAssertEqual(probe.maximumActiveCount, 1)
        XCTAssertEqual(probe.cancelledCompletions, [true])

        probe.finishNext()
        await next.value
        XCTAssertEqual(probe.cancelledCompletions, [true, false])
    }

    func testAlreadyCancelledCallerDoesNotCapture() async {
        let probe = CaptureProbe()
        let coordinator = MenuBarCaptureCoordinator<Int>(operation: probe.capture)
        let caller = Task { await coordinator.request([1]) }
        caller.cancel()
        await caller.value

        XCTAssertTrue(probe.sections.isEmpty)
        XCTAssertEqual(coordinator.pendingRequestCount, 0)
    }
}
