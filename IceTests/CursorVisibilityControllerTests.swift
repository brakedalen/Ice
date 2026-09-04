//
//  CursorVisibilityControllerTests.swift
//  IceTests
//

import CoreGraphics
import os.lock
import XCTest
@testable import Ice

final class CursorVisibilityControllerTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        struct Counts {
            var hide = 0
            var show = 0
            var restoration = 0
        }

        let counts = OSAllocatedUnfairLock(initialState: Counts())
        let messages = OSAllocatedUnfairLock(initialState: [String]())

        func makeController() -> CursorVisibilityController {
            CursorVisibilityController(
                hideOperation: { [self] in
                    counts.withLock { $0.hide += 1 }
                    return .success
                },
                showOperation: { [self] in
                    counts.withLock { $0.show += 1 }
                    return .success
                },
                diagnosticLog: { [self] message, _ in
                    messages.withLock { $0.append(message) }
                }
            )
        }
    }

    func testLeaseBalancesCursorHideExactlyOnce() {
        let recorder = Recorder()
        let controller = recorder.makeController()
        let lease = controller.acquire(owner: "test", watchdogTimeout: .seconds(10))

        XCTAssertTrue(
            lease.release {
                recorder.counts.withLock { $0.restoration += 1 }
            }
        )
        XCTAssertFalse(lease.release())

        recorder.counts.withLock { counts in
            XCTAssertEqual(counts.hide, 1)
            XCTAssertEqual(counts.show, 1)
            XCTAssertEqual(counts.restoration, 1)
        }
    }

    func testNestedAcquisitionDoesNotIncrementQuartzHideCount() {
        let recorder = Recorder()
        let controller = recorder.makeController()
        let firstLease = controller.acquire(owner: "first", watchdogTimeout: .seconds(10))
        let nestedLease = controller.acquire(owner: "nested", watchdogTimeout: .seconds(10))

        XCTAssertFalse(nestedLease.release())
        recorder.counts.withLock { counts in
            XCTAssertEqual(counts.hide, 1)
            XCTAssertEqual(counts.show, 0)
        }

        XCTAssertTrue(firstLease.release())
        recorder.counts.withLock { counts in
            XCTAssertEqual(counts.hide, 1)
            XCTAssertEqual(counts.show, 1)
        }
    }

    func testWatchdogRestoresCursorAndPreventsStaleWarp() async throws {
        let recorder = Recorder()
        let controller = recorder.makeController()
        let lease = controller.acquire(owner: "watchdog", watchdogTimeout: .milliseconds(20))

        try await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(
            lease.release {
                recorder.counts.withLock { $0.restoration += 1 }
            }
        )
        recorder.counts.withLock { counts in
            XCTAssertEqual(counts.hide, 1)
            XCTAssertEqual(counts.show, 1)
            XCTAssertEqual(counts.restoration, 0)
        }
        XCTAssertTrue(
            recorder.messages.withLock { messages in
                messages.contains { $0.contains("CURSOR_HIDE_WATCHDOG_RELEASED") }
            }
        )
    }

    func testNormalReleaseCancelsWatchdog() async throws {
        let recorder = Recorder()
        let controller = recorder.makeController()
        let lease = controller.acquire(owner: "normal", watchdogTimeout: .milliseconds(20))

        XCTAssertTrue(lease.release())
        try await Task.sleep(for: .milliseconds(100))

        recorder.counts.withLock { counts in
            XCTAssertEqual(counts.hide, 1)
            XCTAssertEqual(counts.show, 1)
        }
        XCTAssertFalse(
            recorder.messages.withLock { messages in
                messages.contains { $0.contains("CURSOR_HIDE_WATCHDOG_RELEASED") }
            }
        )
    }
}
