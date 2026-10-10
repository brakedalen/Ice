//
//  MenuBarLayoutMovePolicyTests.swift
//  IceTests
//

import XCTest
@testable import Ice

final class MenuBarLayoutMovePolicyTests: XCTestCase {
    func testNativeEditorReservesAnchorWithoutUserDrag() {
        for showOnDrag in [false, true] {
            XCTAssertEqual(MenuBarLayoutMovePolicy.collapsedDividerLength(
                usesNativeMenuBar: true,
                isLayoutEditorMoveActive: true,
                showOnDrag: showOnDrag,
                isDragging: false
            ), 3)
        }
    }

    func testAnchorCollapsesAfterEditorFinishes() {
        XCTAssertEqual(MenuBarLayoutMovePolicy.collapsedDividerLength(
            usesNativeMenuBar: true,
            isLayoutEditorMoveActive: false,
            showOnDrag: true,
            isDragging: false
        ), 0)
    }

    func testMacOS27EditorDoesNotReserveNativeAnchor() {
        XCTAssertEqual(MenuBarLayoutMovePolicy.collapsedDividerLength(
            usesNativeMenuBar: false,
            isLayoutEditorMoveActive: true,
            showOnDrag: true,
            isDragging: false
        ), 0)
    }

    func testUserCommandDragStillRespectsMarkerPreference() {
        for usesNativeMenuBar in [false, true] {
            for showOnDrag in [false, true] {
                XCTAssertEqual(MenuBarLayoutMovePolicy.collapsedDividerLength(
                    usesNativeMenuBar: usesNativeMenuBar,
                    isLayoutEditorMoveActive: false,
                    showOnDrag: showOnDrag,
                    isDragging: true
                ), showOnDrag ? 3 : 0)
            }
        }
    }

    func testRehideQueuedBeforeMoveIsRejectedDuringReveal() {
        XCTAssertFalse(MenuBarLayoutMovePolicy.allowsDeferredSectionChange(
            capturedGeneration: 6, currentGeneration: 7, isLayoutEditorMoveActive: true
        ))
    }

    func testRehideQueuedDuringMoveIsRejected() {
        XCTAssertFalse(MenuBarLayoutMovePolicy.allowsDeferredSectionChange(
            capturedGeneration: 7, currentGeneration: 7, isLayoutEditorMoveActive: true
        ))
    }

    func testCompletedMoveStillInvalidatesEarlierRehide() {
        XCTAssertFalse(MenuBarLayoutMovePolicy.allowsDeferredSectionChange(
            capturedGeneration: 6, currentGeneration: 8, isLayoutEditorMoveActive: false
        ))
    }

    func testCurrentRehideIsAllowedAfterMove() {
        XCTAssertTrue(MenuBarLayoutMovePolicy.allowsDeferredSectionChange(
            capturedGeneration: 8, currentGeneration: 8, isLayoutEditorMoveActive: false
        ))
    }
}
