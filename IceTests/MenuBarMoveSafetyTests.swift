//
//  MenuBarMoveSafetyTests.swift
//  IceTests
//

import CoreGraphics
import XCTest
@testable import Ice

final class MenuBarMoveSafetyTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)

    func testAcceptsMoveFullyContainedByDisplay() {
        XCTAssertTrue(
            MenuBarMoveSafety.endpointsAreSafe(
                start: CGPoint(x: 1_500, y: 0),
                end: CGPoint(x: 1_475, y: 0),
                sourceBounds: CGRect(x: 1_600, y: 0, width: 25, height: 30),
                targetBounds: CGRect(x: 1_500, y: 0, width: 25, height: 30),
                displayBounds: display
            )
        )
    }

    func testRejectsOffscreenCommandDragEndpoint() {
        XCTAssertFalse(
            MenuBarMoveSafety.endpointsAreSafe(
                start: CGPoint(x: -1_660, y: 0),
                end: CGPoint(x: -1_685, y: 0),
                sourceBounds: CGRect(x: 1_600, y: 0, width: 25, height: 30),
                targetBounds: CGRect(x: -1_660, y: 0, width: 25, height: 30),
                displayBounds: display
            )
        )
    }

    func testRejectsEndpointBeyondDisplayEdge() {
        XCTAssertFalse(
            MenuBarMoveSafety.endpointsAreSafe(
                start: CGPoint(x: 10, y: 0),
                end: CGPoint(x: -15, y: 0),
                sourceBounds: CGRect(x: 100, y: 0, width: 25, height: 30),
                targetBounds: CGRect(x: 10, y: 0, width: 25, height: 30),
                displayBounds: display
            )
        )
    }

    func testRecognizesImmediateNeighborOnRequestedSide() {
        XCTAssertTrue(MenuBarMoveSafety.isImmediateNeighbor(itemIndex: 2, targetIndex: 3, side: .left))
        XCTAssertTrue(MenuBarMoveSafety.isImmediateNeighbor(itemIndex: 4, targetIndex: 3, side: .right))
    }

    func testRejectsNonNeighborAndWrongSide() {
        XCTAssertFalse(MenuBarMoveSafety.isImmediateNeighbor(itemIndex: 1, targetIndex: 3, side: .left))
        XCTAssertFalse(MenuBarMoveSafety.isImmediateNeighbor(itemIndex: 4, targetIndex: 3, side: .left))
    }

    func testMatchesImmediateNeighborByExactWindowID() {
        let orderedWindowIDs: [CGWindowID] = [261, 263, 117]

        XCTAssertTrue(
            MenuBarMoveSafety.hasImmediateNeighbor(
                itemWindowID: 263,
                targetWindowID: 117,
                orderedWindowIDs: orderedWindowIDs,
                side: .left
            )
        )
        XCTAssertFalse(
            MenuBarMoveSafety.hasImmediateNeighbor(
                itemWindowID: 261,
                targetWindowID: 117,
                orderedWindowIDs: orderedWindowIDs,
                side: .left
            )
        )
        XCTAssertFalse(
            MenuBarMoveSafety.hasImmediateNeighbor(
                itemWindowID: 999,
                targetWindowID: 117,
                orderedWindowIDs: orderedWindowIDs,
                side: .left
            )
        )
    }

    func testAcceptsParkedOneDriveBoundsFromStartupRegression() {
        XCTAssertTrue(
            MenuBarMoveSafety.edgesAreAdjacent(
                itemBounds: CGRect(x: -2_369, y: 0, width: 23, height: 30),
                targetBounds: CGRect(x: -2_346, y: 0, width: 5_003, height: 30),
                side: .left
            )
        )
    }

    func testAcceptsParkedBatteryBoundsWithCompactSpacing() {
        XCTAssertTrue(
            MenuBarMoveSafety.edgesAreAdjacent(
                itemBounds: CGRect(x: -2_394, y: 0, width: 29, height: 30),
                targetBounds: CGRect(x: -2_365, y: 0, width: 19, height: 30),
                side: .left
            )
        )
    }

    func testAcceptsSmallRoundingErrorAndRejectsWrongParkedPosition() {
        let target = CGRect(x: 100, y: 0, width: 20, height: 30)

        XCTAssertTrue(
            MenuBarMoveSafety.edgesAreAdjacent(
                itemBounds: CGRect(x: 80.5, y: 0, width: 20, height: 30),
                targetBounds: target,
                side: .left
            )
        )
        XCTAssertFalse(
            MenuBarMoveSafety.edgesAreAdjacent(
                itemBounds: CGRect(x: 78, y: 0, width: 20, height: 30),
                targetBounds: target,
                side: .left
            )
        )
        XCTAssertFalse(
            MenuBarMoveSafety.edgesAreAdjacent(
                itemBounds: CGRect(x: 80, y: 0, width: 20, height: 30),
                targetBounds: target,
                side: .right
            )
        )
    }

    func testMoveEventsAlwaysTargetWindowOwner() {
        XCTAssertEqual(
            MenuBarItemManager.moveEventTargetPID(sourcePID: 80_683, ownerPID: 827),
            827
        )
        XCTAssertEqual(
            MenuBarItemManager.moveEventTargetPID(sourcePID: nil, ownerPID: 827),
            827
        )
    }
}
