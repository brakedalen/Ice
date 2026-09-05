//
//  MenuBarAppearanceUpdatePolicy.swift
//  Ice
//

import Foundation

/// The resources actually consumed by the overlay's drawing paths.
/// Keeping this policy explicit prevents invisible effects from requesting AX
/// menu geometry or screen captures, while retaining the editor's live preview.
struct MenuBarAppearanceUpdatePolicy {
    let needsOverlay: Bool
    let needsApplicationMenuFrame: Bool
    let needsDesktopWallpaper: Bool

    init(
        configuration: MenuBarAppearanceConfigurationV2,
        preview: MenuBarAppearancePartialConfiguration? = nil
    ) {
        let current = preview ?? configuration.current
        needsOverlay = configuration.shapeKind != .noShape || current.hasShadow ||
            current.hasBorder || current.tintKind != .noTint
        needsApplicationMenuFrame = configuration.shapeKind == .split
        needsDesktopWallpaper = configuration.shapeKind != .noShape
    }

    /// macOS can publish an application switch before its menu geometry settles.
    /// Refresh promptly, then back off, with a finite ten-second observation window.
    /// Every attempt after the initial one suspends, even when validation fails.
    static let applicationMenuRefreshDelays: [Duration] = [
        .zero, .milliseconds(100), .milliseconds(100), .milliseconds(200),
        .milliseconds(500), .seconds(1), .seconds(1), .seconds(1),
        .seconds(2), .seconds(2), .seconds(2),
    ]

    /// Theme-dependent wallpaper changes can finish after the theme notification.
    static let wallpaperRefreshDelays: [Duration] = [
        .zero, .seconds(1), .seconds(1), .seconds(1), .seconds(1),
    ]

    /// The callback returns false when the consumer no longer needs this work.
    @MainActor
    static func performRefreshes(delays: [Duration], refresh: (Int) -> Bool) async throws {
        for (index, delay) in delays.enumerated() {
            if delay > .zero {
                try await Task.sleep(for: delay)
            }
            try Task.checkCancellation()
            guard refresh(index) else { return }
        }
    }
}
