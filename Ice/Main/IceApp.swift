//
//  IceApp.swift
//  Ice
//

import SwiftUI

@main
enum IceEntryPoint {
    @MainActor
    static func main() {
        #if DEBUG
        // The test scheme uses an inert host: never instantiate AppState,
        // migrate settings, create status items, or run placement automation.
        if ProcessInfo.processInfo.environment["ICE_UNIT_TESTING"] == "1" {
            IceUnitTestHost.main()
            return
        }
        #endif
        IceApp.main()
    }
}

private struct IceUnitTestHost: App {
    var body: some Scene {
        Settings { EmptyView() }
    }
}

struct IceApp: App {
    @NSApplicationDelegateAdaptor var appDelegate: AppDelegate

    var body: some Scene {
        SettingsWindow(appState: appDelegate.appState)
        PermissionsWindow(appState: appDelegate.appState)
    }
}
