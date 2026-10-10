//
//  MenuBarMoveVerificationTests.swift
//  IceTests
//

import CoreGraphics
import XCTest
@testable import Ice

final class MenuBarMoveVerificationTests: XCTestCase {
    func testVerifiesDropWhenSourceFallsOutOfOnScreenEnumeration() {
        // Regression: Magnet -> left of Wi-Fi, 10 Oct 2026. Preflight
        // succeeds, but moving left hides Magnet from the on-screen list.
        let itemWindowID: CGWindowID = 71
        let targetWindowID: CGWindowID = 36
        XCTAssertFalse(MenuBarMoveSafety.hasImmediateNeighbor(
            itemWindowID: itemWindowID,
            targetWindowID: targetWindowID,
            orderedWindowIDs: [targetWindowID],
            side: .left
        ))
        XCTAssertTrue(MenuBarMoveSafety.edgesAreAdjacent(
            itemBounds: CGRect(x: 703, y: 0, width: 25, height: 39),
            targetBounds: CGRect(x: 728, y: 0, width: 25, height: 39),
            side: .left
        ))
    }

    func testRejectsWrongPositionEvenWhenBothWindowsStillExist() {
        XCTAssertFalse(MenuBarMoveSafety.edgesAreAdjacent(
            itemBounds: CGRect(x: 1394, y: 0, width: 25, height: 39),
            targetBounds: CGRect(x: 728, y: 0, width: 25, height: 39),
            side: .left
        ))
    }

    func testLayoutMoveWaitsForSustainedCorrectPosition() {
        var stability = MenuBarMoveSafety.PositionStability(minimumDuration: .milliseconds(200))
        XCTAssertFalse(stability.observe(isCorrect: true, elapsed: .zero))
        XCTAssertFalse(stability.observe(isCorrect: true, elapsed: .milliseconds(199)))
        XCTAssertTrue(stability.observe(isCorrect: true, elapsed: .milliseconds(200)))
    }

    func testTransientCorrectPositionDoesNotConfirmMove() {
        var stability = MenuBarMoveSafety.PositionStability(minimumDuration: .milliseconds(200))
        XCTAssertFalse(stability.observe(isCorrect: true, elapsed: .zero))
        XCTAssertFalse(stability.observe(isCorrect: false, elapsed: .milliseconds(100)))
        XCTAssertFalse(stability.observe(isCorrect: true, elapsed: .milliseconds(150)))
        XCTAssertFalse(stability.observe(isCorrect: true, elapsed: .milliseconds(349)))
        XCTAssertTrue(stability.observe(isCorrect: true, elapsed: .milliseconds(350)))
    }

    func testInternalMovesKeepImmediateVerification() {
        var stability = MenuBarMoveSafety.PositionStability(minimumDuration: .zero)
        XCTAssertTrue(stability.observe(isCorrect: true, elapsed: .zero))
        XCTAssertFalse(stability.observe(isCorrect: false, elapsed: .milliseconds(10)))
    }
}
