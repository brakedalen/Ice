//
//  MenuBarAppearanceTests.swift
//  IceTests
//

import Cocoa
import XCTest
@testable import Ice

final class MenuBarAppearanceTests: XCTestCase {
    func testNoEffectsRequireNoOverlayOrCaptureWork() {
        let policy = MenuBarAppearanceUpdatePolicy(configuration: .defaultConfiguration)
        XCTAssertFalse(policy.needsOverlay)
        XCTAssertFalse(policy.needsApplicationMenuFrame)
        XCTAssertFalse(policy.needsDesktopWallpaper)
    }

    func testUnshapedEffectsDoNotRequireWallpaperOrMenuGeometry() {
        for effect in 0..<3 {
            var configuration = MenuBarAppearanceConfigurationV2.defaultConfiguration
            switch effect {
            case 0: configuration.staticConfiguration.hasShadow = true
            case 1: configuration.staticConfiguration.hasBorder = true
            default: configuration.staticConfiguration.tintKind = .solid
            }
            let policy = MenuBarAppearanceUpdatePolicy(configuration: configuration)
            XCTAssertTrue(policy.needsOverlay)
            XCTAssertFalse(policy.needsApplicationMenuFrame)
            XCTAssertFalse(policy.needsDesktopWallpaper)
        }
    }

    func testFullShapeOnlyRequiresWallpaper() {
        var configuration = MenuBarAppearanceConfigurationV2.defaultConfiguration
        configuration.shapeKind = .full
        let policy = MenuBarAppearanceUpdatePolicy(configuration: configuration)
        XCTAssertTrue(policy.needsOverlay)
        XCTAssertFalse(policy.needsApplicationMenuFrame)
        XCTAssertTrue(policy.needsDesktopWallpaper)
    }

    func testSplitShapeRequiresWallpaperAndMenuGeometry() {
        var configuration = MenuBarAppearanceConfigurationV2.defaultConfiguration
        configuration.shapeKind = .split
        let policy = MenuBarAppearanceUpdatePolicy(configuration: configuration)
        XCTAssertTrue(policy.needsOverlay)
        XCTAssertTrue(policy.needsApplicationMenuFrame)
        XCTAssertTrue(policy.needsDesktopWallpaper)
    }

    func testPreviewCanEnableAndDisableAnOverlayWithoutChangingSavedSettings() {
        var configuration = MenuBarAppearanceConfigurationV2.defaultConfiguration
        var preview = MenuBarAppearancePartialConfiguration.defaultConfiguration
        preview.hasBorder = true
        XCTAssertTrue(MenuBarAppearanceUpdatePolicy(configuration: configuration, preview: preview).needsOverlay)
        XCTAssertFalse(MenuBarAppearanceUpdatePolicy(configuration: configuration).needsOverlay)

        configuration.staticConfiguration.hasShadow = true
        XCTAssertFalse(MenuBarAppearanceUpdatePolicy(configuration: configuration, preview: .defaultConfiguration).needsOverlay)
        XCTAssertTrue(MenuBarAppearanceUpdatePolicy(configuration: configuration).needsOverlay)
    }

    func testRefreshSchedulesAreBoundedAndCannotBusyLoop() {
        let delays = MenuBarAppearanceUpdatePolicy.applicationMenuRefreshDelays
        XCTAssertEqual(delays.first, .zero)
        XCTAssertLessThanOrEqual(delays.count, 11)
        XCTAssertLessThanOrEqual(delays.reduce(.zero, +), .seconds(10))
        XCTAssertTrue(delays.dropFirst().allSatisfy { $0 >= .milliseconds(100) })

        let wallpaperDelays = MenuBarAppearanceUpdatePolicy.wallpaperRefreshDelays
        XCTAssertEqual(wallpaperDelays.count, 5)
        XCTAssertTrue(wallpaperDelays.dropFirst().allSatisfy { $0 >= .seconds(1) })
    }

    @MainActor
    func testRefreshStopsWhenItsConsumerNoLongerNeedsWork() async throws {
        var attempts = 0
        try await MenuBarAppearanceUpdatePolicy.performRefreshes(delays: [.zero, .zero, .zero]) { _ in
            attempts += 1
            return false
        }
        XCTAssertEqual(attempts, 1)
    }

    @MainActor
    func testRefreshPerformsOnlyScheduledAttempts() async throws {
        var indices = [Int]()
        try await MenuBarAppearanceUpdatePolicy.performRefreshes(delays: [.zero, .zero, .zero]) { index in
            indices.append(index)
            return true
        }
        XCTAssertEqual(indices, [0, 1, 2])
    }

    @MainActor
    func testCancelledRefreshNeverCallsItsConsumer() async {
        var attempts = 0
        let task = Task { @MainActor in
            try await MenuBarAppearanceUpdatePolicy.performRefreshes(delays: [.zero]) { _ in
                attempts += 1
                return true
            }
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("Cancelled appearance work should throw cancellation")
        } catch is CancellationError {
            XCTAssertEqual(attempts, 0)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testCancellationStopsARefreshThatIsWaitingToRetry() async {
        let firstAttempt = expectation(description: "Initial refresh")
        var attempts = 0
        let task = Task { @MainActor in
            try await MenuBarAppearanceUpdatePolicy.performRefreshes(delays: [.zero, .seconds(30)]) { _ in
                attempts += 1
                firstAttempt.fulfill()
                return true
            }
        }
        await fulfillment(of: [firstAttempt], timeout: 1)
        task.cancel()
        do {
            try await task.value
            XCTFail("Sleeping appearance work should honor cancellation")
        } catch is CancellationError {
            XCTAssertEqual(attempts, 1)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testColorSamplingRemainsFiniteWhenTheRowFillsOrExceedsTheScreen() {
        let screen = CGRect(x: -1_000, y: 0, width: 1_000, height: 800)
        for width in [1_000.0, 1_100.0] {
            let row = CGRect(x: -1_000, y: 700, width: width, height: 30)
            XCTAssertEqual(IceBarColorManager.samplePercentage(for: row, in: screen), 0.5)
        }
    }

    @MainActor
    func testColorSamplingHandlesBothEndsOfANegativeOriginDisplay() {
        let screen = CGRect(x: -1_000, y: 0, width: 1_000, height: 800)
        XCTAssertEqual(IceBarColorManager.samplePercentage(for: CGRect(x: -1_000, y: 700, width: 200, height: 30), in: screen), 0)
        XCTAssertEqual(IceBarColorManager.samplePercentage(for: CGRect(x: -200, y: 700, width: 200, height: 30), in: screen), 1)
    }
}
