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

extension MenuBarLayoutMovePolicy {
    /// How far left a layout-editor move must expose the native menu bar.
    /// Sections are ordered right to left, so exposing a section also
    /// requires exposing every section to its right.
    enum RevealDepth: Int, Comparable {
        case visible = 0
        case hidden = 1
        case alwaysHidden = 2

        init(section: MenuBarSection.Name) {
            switch section {
            case .visible: self = .visible
            case .hidden: self = .hidden
            case .alwaysHidden: self = .alwaysHidden
            }
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        /// Whether the given section must be shown at this depth.
        func reveals(_ section: MenuBarSection.Name) -> Bool {
            RevealDepth(section: section) <= self
        }
    }

    /// The depth one move endpoint needs. Dividers need the section on their
    /// left, because a collapsed divider extends off the left of the display.
    /// Unknown endpoints keep the previous behavior of revealing everything.
    static func revealDepth(
        tag: MenuBarItemTag,
        cachedSection: MenuBarSection.Name?
    ) -> RevealDepth {
        if tag == .visibleControlItem {
            return .visible
        }
        if tag == .hiddenControlItem {
            return .hidden
        }
        if tag == .alwaysHiddenControlItem {
            return .alwaysHidden
        }
        guard let cachedSection else {
            return .alwaysHidden
        }
        return RevealDepth(section: cachedSection)
    }

    /// Only the sections containing the endpoints are exposed. Revealing
    /// everything overflows a notched menu bar with many items, which pushes
    /// the endpoints behind the notch and makes every move unsafe.
    static func revealDepth(
        source: (tag: MenuBarItemTag, section: MenuBarSection.Name?),
        target: (tag: MenuBarItemTag, section: MenuBarSection.Name?)
    ) -> RevealDepth {
        max(
            revealDepth(tag: source.tag, cachedSection: source.section),
            revealDepth(tag: target.tag, cachedSection: target.section)
        )
    }

    /// Whether a move that cannot be made on the visible menu bar may fall
    /// back to the off-screen move used by internal operations. Control
    /// Center items can be removed by an off-screen mouse-up, so they never
    /// fall back.
    static func allowsOffscreenFallback(
        sourceTag: MenuBarItemTag,
        targetTag: MenuBarItemTag
    ) -> Bool {
        sourceTag.namespace != .controlCenter && targetTag.namespace != .controlCenter
    }
}
