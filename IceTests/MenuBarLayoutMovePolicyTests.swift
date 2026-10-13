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

    private let app = MenuBarItemTag(namespace: .string("com.lujjjh.LinearMouse"), title: "Item-0")
    private let wifi = MenuBarItemTag(namespace: .controlCenter, title: "WiFi")

    func testRevealOnlyExposesEndpointSections() {
        XCTAssertEqual(MenuBarLayoutMovePolicy.revealDepth(
            source: (app, .visible),
            target: (wifi, .visible)
        ), .visible)
        XCTAssertEqual(MenuBarLayoutMovePolicy.revealDepth(
            source: (app, .hidden),
            target: (wifi, .visible)
        ), .hidden)
        XCTAssertEqual(MenuBarLayoutMovePolicy.revealDepth(
            source: (app, .visible),
            target: (wifi, .alwaysHidden)
        ), .alwaysHidden)
    }

    func testDividerTargetsExposeSectionOnTheirLeft() {
        XCTAssertEqual(MenuBarLayoutMovePolicy.revealDepth(
            source: (app, .visible),
            target: (.hiddenControlItem, nil)
        ), .hidden)
        XCTAssertEqual(MenuBarLayoutMovePolicy.revealDepth(
            source: (app, .visible),
            target: (.alwaysHiddenControlItem, nil)
        ), .alwaysHidden)
        XCTAssertEqual(MenuBarLayoutMovePolicy.revealDepth(
            source: (app, .visible),
            target: (.visibleControlItem, nil)
        ), .visible)
    }

    func testUnknownEndpointRevealsEverything() {
        XCTAssertEqual(MenuBarLayoutMovePolicy.revealDepth(
            source: (app, nil),
            target: (wifi, .visible)
        ), .alwaysHidden)
    }

    func testRevealDepthIncludesSectionsToTheRight() {
        let depth = MenuBarLayoutMovePolicy.RevealDepth.hidden
        XCTAssertTrue(depth.reveals(.visible))
        XCTAssertTrue(depth.reveals(.hidden))
        XCTAssertFalse(depth.reveals(.alwaysHidden))
    }

    func testControlCenterNeverFallsBackOffscreen() {
        let other = MenuBarItemTag(namespace: .string("com.openai.codex"), title: "Item-0")
        XCTAssertTrue(MenuBarLayoutMovePolicy.allowsOffscreenFallback(sourceTag: app, targetTag: other))
        XCTAssertFalse(MenuBarLayoutMovePolicy.allowsOffscreenFallback(sourceTag: app, targetTag: wifi))
        XCTAssertFalse(MenuBarLayoutMovePolicy.allowsOffscreenFallback(sourceTag: wifi, targetTag: app))
    }
}
