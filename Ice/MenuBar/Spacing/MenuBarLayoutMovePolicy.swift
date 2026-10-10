//
//  MenuBarLayoutMovePolicy.swift
//  Ice
//

import CoreGraphics

/// Rules for keeping a native layout move's temporary reveal intact.
enum MenuBarLayoutMovePolicy {
    static func collapsedDividerLength(
        usesNativeMenuBar: Bool,
        isLayoutEditorMoveActive: Bool,
        showOnDrag: Bool,
        isDragging: Bool
    ) -> CGFloat {
        // macOS 27 uses saved app sections, not native divider windows.
        let needsMoveAnchor = usesNativeMenuBar && isLayoutEditorMoveActive
        return needsMoveAnchor || (showOnDrag && isDragging) ? 3 : 0
    }

    static func allowsDeferredSectionChange(
        capturedGeneration: UInt64,
        currentGeneration: UInt64,
        isLayoutEditorMoveActive: Bool
    ) -> Bool {
        !isLayoutEditorMoveActive && capturedGeneration == currentGeneration
    }
}
