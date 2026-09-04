//
//  ScreenCapture.swift
//  Ice
//

import CoreGraphics
import ScreenCaptureKit

/// A namespace for screen capture operations.
enum ScreenCapture {
    /// Result of capturing independent, on-screen windows through
    /// ScreenCaptureKit. Missing windows are intentionally returned to the
    /// caller so it can use the legacy API for off-screen status items.
    struct ModernWindowCaptureResult {
        var images = [CGWindowID: CGImage]()
        var unavailableWindowIDs = Set<CGWindowID>()
        var errorDescription: String?
    }

    // MARK: Permissions

    /// Returns a Boolean value that indicates whether the app has screen
    /// capture permissions.
    static func checkPermissions() -> Bool {
        for windowID in Bridging.getMenuBarWindowList(option: [.itemsOnly, .activeSpace]) {
            guard
                let window = WindowInfo(windowID: windowID),
                window.owningApplication != .current // Skip windows we own.
            else {
                continue
            }
            return window.title != nil
        }
        // CGPreflightScreenCaptureAccess() only returns an initial value,
        // but we can use it as a fallback.
        return CGPreflightScreenCaptureAccess()
    }

    /// Returns a Boolean value that indicates whether the app has screen
    /// capture permissions.
    ///
    /// This function caches its initial result and returns it on subsequent
    /// calls. Pass `true` to the `reset` parameter to replace the cached
    /// result with a newly computed value.
    static func cachedCheckPermissions(reset: Bool = false) -> Bool {
        enum Context {
            static var cachedResult: Bool?
        }
        if !reset, let result = Context.cachedResult, result {
            return result
        }
        let result = checkPermissions()
        Context.cachedResult = result
        return result
    }

    /// Requests screen capture permissions.
    static func requestPermissions() {
        if #available(macOS 15.0, *) {
            // CGRequestScreenCaptureAccess() is broken on macOS 15. We can
            // try accessing SCShareableContent to trigger a request if the
            // user doesn't have permissions.
            // TODO: Find out if we still need this as of macOS 26.
            SCShareableContent.getWithCompletionHandler { _, _ in }
        } else {
            CGRequestScreenCaptureAccess()
        }
    }

    // MARK: Capture Window(s)

    /// Captures a composite image of an array of windows.
    ///
    /// The windows are composited from front to back, according to the order
    /// of the `windowIDs` parameter.
    ///
    /// - Parameters:
    ///   - windowIDs: The identifiers of the windows to capture.
    ///   - screenBounds: The bounds to capture, specified in screen coordinates.
    ///     Pass `nil` to capture the minimum rectangle that encloses the windows.
    ///   - option: Options that specify which parts of the windows are captured.
    static func captureWindows(with windowIDs: [CGWindowID], screenBounds: CGRect? = nil, option: CGWindowImageOption = []) -> CGImage? {
        guard let array = Bridging.createCGWindowArray(with: windowIDs) else {
            return nil
        }
        let bounds = screenBounds ?? .null
        // ScreenCaptureKit doesn't support capturing images of offscreen menu bar
        // items, so we unfortunately have to use the deprecated CGWindowList API.
        return CGImage.windowListImage(from: bounds, windowArray: array, imageOption: option)
    }

    /// Captures an image of a window.
    ///
    /// - Parameters:
    ///   - windowID: The identifier of the window to capture.
    ///   - screenBounds: The bounds to capture, specified in screen coordinates.
    ///     Pass `nil` to capture the minimum rectangle that encloses the window.
    ///   - option: Options that specify which parts of the window are captured.
    static func captureWindow(with windowID: CGWindowID, screenBounds: CGRect? = nil, option: CGWindowImageOption = []) -> CGImage? {
        captureWindows(with: [windowID], screenBounds: screenBounds, option: option)
    }

    /// Captures independent on-screen windows with ScreenCaptureKit.
    ///
    /// ScreenCaptureKit deliberately omits off-screen menu bar windows. Those
    /// identifiers are reported as unavailable instead of treated as errors,
    /// allowing callers to limit deprecated CGWindowList capture to the cases
    /// where no modern equivalent exists.
    static func captureOnScreenWindows(
        with windowIDs: Set<CGWindowID>,
        scale: CGFloat
    ) async -> ModernWindowCaptureResult {
        guard !windowIDs.isEmpty else {
            return ModernWindowCaptureResult()
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            let windowsByID = Dictionary(
                uniqueKeysWithValues: content.windows
                    .filter { windowIDs.contains($0.windowID) }
                    .map { ($0.windowID, $0) }
            )

            var result = ModernWindowCaptureResult()
            result.unavailableWindowIDs = windowIDs.subtracting(windowsByID.keys)

            for windowID in windowIDs.sorted() {
                guard let window = windowsByID[windowID] else {
                    continue
                }
                let configuration = SCStreamConfiguration()
                configuration.width = max(Int(window.frame.width * scale), 1)
                configuration.height = max(Int(window.frame.height * scale), 1)
                configuration.scalesToFit = true
                configuration.showsCursor = false
                configuration.ignoreShadowsSingleWindow = true
                configuration.ignoreGlobalClipSingleWindow = true

                do {
                    let filter = SCContentFilter(desktopIndependentWindow: window)
                    let image = try await SCScreenshotManager.captureImage(
                        contentFilter: filter,
                        configuration: configuration
                    )
                    result.images[windowID] = image
                } catch {
                    result.unavailableWindowIDs.insert(windowID)
                    result.errorDescription = String(describing: error)
                }
            }
            return result
        } catch {
            return ModernWindowCaptureResult(
                unavailableWindowIDs: windowIDs,
                errorDescription: String(describing: error)
            )
        }
    }
}

/// A protocol used to isolate the deprecated `CGWindowList` screen capture API.
///
/// ScreenCaptureKit doesn't support capturing composite images of offscreen
/// menu bar items, but this should be replaced once it does.
private protocol WindowListImage {
    init?(
        windowListFromArrayScreenBounds: CGRect,
        windowArray: CFArray,
        imageOption: CGWindowImageOption
    )
}

private extension WindowListImage {
    static func windowListImage(
        from screenBounds: CGRect,
        windowArray: CFArray,
        imageOption: CGWindowImageOption
    ) -> Self? {
        Self(
            windowListFromArrayScreenBounds: screenBounds,
            windowArray: windowArray,
            imageOption: imageOption
        )
    }
}

extension CGImage: WindowListImage { }
