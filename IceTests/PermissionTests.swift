//
//  PermissionTests.swift
//  IceTests
//

import Combine
import XCTest
@testable import Ice

@MainActor
final class PermissionTests: XCTestCase {
    @MainActor
    private final class State {
        var granted = false
        var time: TimeInterval = 0
        var checkCount = 0
        var synchronizedValues = [Bool]()

        func makePermission(isRequired: Bool = true) -> Permission {
            Permission(
                title: "Test",
                details: [],
                isRequired: isRequired,
                check: {
                    self.checkCount += 1
                    return self.granted
                },
                request: {},
                onCheck: { self.synchronizedValues.append($0) },
                now: { self.time },
                schedulesChecks: false,
                diagnosticLog: { _ in }
            )
        }
    }

    func testUnchangedChecksDoNotPublishAndRealTransitionsSynchronizeConsumers() {
        let state = State()
        let permission = state.makePermission()
        var publications = [Bool]()
        let subscription = permission.$hasPermission.dropFirst().sink { granted in
            // Capture consumers must already have the new value when UI
            // observers receive the permission transition.
            XCTAssertEqual(state.synchronizedValues.last, granted)
            publications.append(granted)
        }
        defer { subscription.cancel() }

        permission.refresh(reason: "unchanged")
        permission.refresh(reason: "unchanged")
        XCTAssertTrue(publications.isEmpty)
        XCTAssertEqual(state.checkCount, 3)

        state.granted = true
        permission.refresh(reason: "grant")
        permission.refresh(reason: "unchanged")
        state.granted = false
        permission.refresh(reason: "revoke")

        XCTAssertEqual(publications, [true, false])
        XCTAssertEqual(state.synchronizedValues, [false, false, false, true, true, false])
    }

    func testFastRequestPollingExpiresWithoutStoppingRevocationChecks() {
        let state = State()
        let permission = state.makePermission()
        XCTAssertEqual(permission.pollingInterval, 30)

        permission.performRequest()
        XCTAssertEqual(permission.pollingInterval, 1)
        state.time = 119
        permission.refresh(reason: "request-pending")
        XCTAssertEqual(permission.pollingInterval, 1)
        state.time = 121
        permission.refresh(reason: "request-expired")
        XCTAssertEqual(permission.pollingInterval, 30)

        state.granted = true
        permission.refresh(reason: "late-grant")
        XCTAssertTrue(permission.hasPermission)
        XCTAssertEqual(permission.pollingInterval, 30)
        state.granted = false
        permission.refresh(reason: "background-revocation")
        XCTAssertFalse(permission.hasPermission)
        XCTAssertEqual(permission.pollingInterval, 30)
    }

    func testPermissionUIOnlyUsesFastPollingWhilePermissionIsMissing() {
        let state = State()
        let permission = state.makePermission()
        permission.setPermissionUIVisible(true)
        XCTAssertEqual(permission.pollingInterval, 1)

        state.granted = true
        permission.refresh(reason: "grant")
        XCTAssertEqual(permission.pollingInterval, 30)
        state.granted = false
        permission.refresh(reason: "revoke")
        XCTAssertEqual(permission.pollingInterval, 1)

        permission.setPermissionUIVisible(false)
        XCTAssertEqual(permission.pollingInterval, 30)
    }

    func testCapturePermissionCacheTracksGrantRevocationAndRegrant() {
        for granted in [true, false, true] {
            ScreenCapture.updateCachedPermissions(granted)
            XCTAssertEqual(ScreenCapture.cachedCheckPermissions(), granted)
        }
        // Leave the isolated test host with a conservative cached value.
        ScreenCapture.updateCachedPermissions(false)
    }

    func testIndividualChangesPropagateWhenAggregateStateStaysMissing() {
        let accessibilityState = State()
        let screenState = State()
        let accessibility = accessibilityState.makePermission()
        let screen = screenState.makePermission(isRequired: false)
        let manager = AppPermissions(accessibility: accessibility, screenRecording: screen, observesLifecycle: false)
        var publications = 0
        let subscription = manager.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }

        manager.refreshAll(reason: "unchanged")
        XCTAssertEqual(publications, 0)
        screenState.granted = true
        screen.refresh(reason: "optional-grant")
        XCTAssertEqual(manager.permissionsState, .missing)
        XCTAssertEqual(publications, 1)

        accessibilityState.granted = true
        accessibility.refresh(reason: "required-grant")
        XCTAssertEqual(manager.permissionsState, .hasAll)
        screenState.granted = false
        screen.refresh(reason: "optional-revocation")
        XCTAssertEqual(manager.permissionsState, .hasRequired)
        XCTAssertEqual(publications, 3)
    }

    func testConcurrentWaitersAllCompleteWhenPermissionIsGranted() async {
        let state = State()
        let permission = state.makePermission()
        let firstFinished = expectation(description: "first request completes")
        let secondFinished = expectation(description: "second request completes")
        let first = Task {
            let granted = await permission.waitForPermission()
            XCTAssertTrue(granted)
            firstFinished.fulfill()
        }
        let second = Task {
            let granted = await permission.waitForPermission()
            XCTAssertTrue(granted)
            secondFinished.fulfill()
        }
        defer {
            first.cancel()
            second.cancel()
            permission.stopCheck()
        }

        await waitForChecks(3, state: state)
        state.granted = true
        permission.refresh(reason: "grant")
        await fulfillment(of: [firstFinished, secondFinished], timeout: 1)
    }

    func testCancellingOneWaiterDoesNotCancelAnother() async {
        let state = State()
        let permission = state.makePermission()
        let cancelled = expectation(description: "cancelled request completes")
        let granted = expectation(description: "remaining request succeeds")
        let first = Task {
            let result = await permission.waitForPermission()
            XCTAssertFalse(result)
            cancelled.fulfill()
        }
        let second = Task {
            let result = await permission.waitForPermission()
            XCTAssertTrue(result)
            granted.fulfill()
        }
        defer {
            first.cancel()
            second.cancel()
            permission.stopCheck()
        }

        await waitForChecks(3, state: state)
        first.cancel()
        await fulfillment(of: [cancelled], timeout: 1)
        state.granted = true
        permission.refresh(reason: "grant")
        await fulfillment(of: [granted], timeout: 1)
    }

    func testAlreadyCancelledWaiterDoesNotStartPolling() async {
        let state = State()
        let permission = state.makePermission()
        let finished = expectation(description: "already cancelled request completes")
        let task = Task {
            let result = await permission.waitForPermission()
            XCTAssertFalse(result)
            finished.fulfill()
        }
        task.cancel() // The main actor has not yielded to the new task yet.
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertEqual(state.checkCount, 1)
        XCTAssertEqual(permission.pollingInterval, 30)
    }

    func testStoppingChecksFinishesPendingWaitersWithoutGrantingPermission() async {
        let state = State()
        let permission = state.makePermission()
        let finished = expectation(description: "stopped request completes")
        let task = Task {
            let result = await permission.waitForPermission()
            XCTAssertFalse(result)
            finished.fulfill()
        }
        defer { task.cancel() }
        await waitForChecks(2, state: state)
        permission.stopCheck()
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertNil(permission.pollingInterval)
        XCTAssertFalse(permission.hasPermission)
    }

    private func waitForChecks(_ count: Int, state: State) async {
        for _ in 0..<100 where state.checkCount < count {
            await Task.yield()
        }
        XCTAssertGreaterThanOrEqual(state.checkCount, count)
    }
}
