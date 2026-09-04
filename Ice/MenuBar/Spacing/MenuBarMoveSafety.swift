//
//  MenuBarMoveSafety.swift
//  Ice
//

import CoreGraphics

/// Pure geometry checks shared by menu bar item and spacer moves.
///
/// Command-dragging a status item outside the physical menu bar removes some
/// system items. Layout-editor moves therefore use these checks before posting
/// any synthetic mouse-up event.
enum MenuBarMoveSafety {
    enum Side {
        case left
        case right
    }

    /// Returns whether a synthesized move is fully contained by one display.
    static func endpointsAreSafe(
        start: CGPoint,
        end: CGPoint,
        sourceBounds: CGRect,
        targetBounds: CGRect,
        displayBounds: CGRect
    ) -> Bool {
        guard
            displayBounds.width > 0,
            displayBounds.height > 0,
            sourceBounds.width > 0,
            sourceBounds.height > 0,
            targetBounds.width > 0,
            targetBounds.height > 0,
            [
                start.x, start.y,
                end.x, end.y,
                sourceBounds.minX, sourceBounds.minY,
                sourceBounds.maxX, sourceBounds.maxY,
                targetBounds.minX, targetBounds.minY,
                targetBounds.maxX, targetBounds.maxY,
            ].allSatisfy(\.isFinite)
        else {
            return false
        }

        return displayBounds.intersects(sourceBounds) &&
        displayBounds.intersects(targetBounds) &&
        containsInclusively(start, in: displayBounds) &&
        containsInclusively(end, in: displayBounds)
    }

    /// Returns whether an item is the immediate neighbor of its target on the
    /// requested side in one consistently ordered WindowServer snapshot.
    static func isImmediateNeighbor(itemIndex: Int, targetIndex: Int, side: Side) -> Bool {
        switch side {
        case .left:
            itemIndex == targetIndex - 1
        case .right:
            itemIndex == targetIndex + 1
        }
    }

    /// Returns whether two exact windows are immediate neighbors in an
    /// ordered WindowServer snapshot.
    ///
    /// Window identifiers are intentionally required here. Tags are not
    /// unique for apps such as OneDrive that publish multiple status items,
    /// and falling back to a tag can verify the wrong live instance.
    static func hasImmediateNeighbor(
        itemWindowID: CGWindowID,
        targetWindowID: CGWindowID,
        orderedWindowIDs: [CGWindowID],
        side: Side
    ) -> Bool {
        guard
            let itemIndex = orderedWindowIDs.firstIndex(of: itemWindowID),
            let targetIndex = orderedWindowIDs.firstIndex(of: targetWindowID)
        else {
            return false
        }
        return isImmediateNeighbor(
            itemIndex: itemIndex,
            targetIndex: targetIndex,
            side: side
        )
    }

    /// Returns whether an item touches the requested edge of its target.
    ///
    /// Hidden sections are parked outside every physical display, so they
    /// cannot be verified by a display-scoped on-screen enumeration. AppKit
    /// still places adjacent status-item windows edge-to-edge in that parking
    /// area; status-item spacing is represented inside the window widths.
    static func edgesAreAdjacent(
        itemBounds: CGRect,
        targetBounds: CGRect,
        side: Side,
        tolerance: CGFloat = 0.5
    ) -> Bool {
        guard
            tolerance.isFinite,
            tolerance >= 0,
            itemBounds.width > 0,
            itemBounds.height > 0,
            targetBounds.width > 0,
            targetBounds.height > 0,
            [
                itemBounds.minX, itemBounds.maxX,
                targetBounds.minX, targetBounds.maxX,
            ].allSatisfy(\.isFinite)
        else {
            return false
        }

        let delta = switch side {
        case .left:
            itemBounds.maxX - targetBounds.minX
        case .right:
            itemBounds.minX - targetBounds.maxX
        }
        return abs(delta) <= tolerance
    }

    private static func containsInclusively(_ point: CGPoint, in rect: CGRect) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX &&
        point.y >= rect.minY && point.y <= rect.maxY
    }
}
