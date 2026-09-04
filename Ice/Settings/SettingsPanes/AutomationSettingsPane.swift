//
//  AutomationSettingsPane.swift
//  Ice
//

import AppKit
import SwiftUI

struct AutomationSettingsPane: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var settings: AutomationSettings
    @ObservedObject var monitor: SystemStateMonitor

    var body: some View {
        IceForm {
            IceSection("Item Positions") {
                rememberItemPositions
                automationLog
            }
            IceSection("Wi-Fi Rule") {
                AutomationRuleView(
                    rule: $settings.wifiRule,
                    optionWhenMet: "Connected to Wi-Fi",
                    optionWhenNotMet: "Not connected to Wi-Fi",
                    statusText: wifiStatusText
                )
            }
            IceSection("Power Rule") {
                AutomationRuleView(
                    rule: $settings.powerRule,
                    optionWhenMet: "Connected to power",
                    optionWhenNotMet: "On battery",
                    statusText: powerStatusText
                )
            }
        }
    }

    private var wifiStatusText: String {
        switch monitor.isWiFiConnected {
        case .some(true): "Currently: connected to Wi-Fi"
        case .some(false): "Currently: not connected to Wi-Fi"
        case .none: "Currently: unknown"
        }
    }

    private var powerStatusText: String {
        switch monitor.isOnExternalPower {
        case .some(true): "Currently: connected to power"
        case .some(false): "Currently: on battery"
        case .none: "Currently: unknown"
        }
    }

    @ViewBuilder
    private var rememberItemPositions: some View {
        Toggle(
            "Remember menu bar item positions",
            isOn: $settings.rememberItemPositions
        )
        .annotation(
            """
            When an app puts its menu bar item back in the wrong section — \
            for example after a restart — Ice moves it back to where it belongs.
            """
        )
    }

    private var automationLog: some View {
        LabeledContent("Diagnostics") {
            Button("Show Log in Finder…") {
                let logger = AutomationDiagnosticLogger.shared
                logger.write("LOG_REVEALED source=automation-settings")
                NSWorkspace.shared.activateFileViewerSelecting([logger.logURL])
            }
        }
        .annotation("Ice records automation details in ~/Library/Logs/Ice/automation.log.")
    }
}

// MARK: - AutomationRuleView

private struct AutomationRuleView: View {
    @Binding var rule: AutomationRule
    let optionWhenMet: String
    let optionWhenNotMet: String
    let statusText: String

    var body: some View {
        Toggle(isOn: $rule.isEnabled) {
            HStack {
                Text("Enable rule")
                BetaBadge()
            }
        }
        .annotation(LocalizedStringKey(statusText))

        if rule.isEnabled {
            IcePicker(
                "Show items when",
                selection: $rule.action
            ) {
                Text(LocalizedStringKey(optionWhenMet))
                    .tag(AutomationRule.Action.showWhenMet)
                Text(LocalizedStringKey(optionWhenNotMet))
                    .tag(AutomationRule.Action.hideWhenMet)
            }
            .annotation(
                """
                Selected items appear at the left edge of the menu bar while the \
                condition matches, and return to their previous spot in the hidden \
                section when it no longer does.
                """
            )

            AutomationItemPicker(selection: $rule.itemKeys)
        }
    }
}

// MARK: - AutomationItemPicker

private struct AutomationItemPicker: View {
    @EnvironmentObject var appState: AppState
    @Binding var selection: Set<String>
    @State private var isChoosingItems = false

    var body: some View {
        LabeledContent {
            Button("Choose Items…") {
                isChoosingItems = true
            }
            .popover(isPresented: $isChoosingItems, arrowEdge: .bottom) {
                ScrollView {
                    AutomationItemPickerContent(
                        itemManager: appState.itemManager,
                        imageCache: appState.imageCache,
                        selection: $selection
                    )
                    .padding()
                }
                .frame(width: 320, height: 380)
            }
        } label: {
            AutomationSelectedItemsSummary(
                itemManager: appState.itemManager,
                imageCache: appState.imageCache,
                selection: selection
            )
        }
    }
}

// MARK: - AutomationSelectedItemsSummary

private struct AutomationSelectedItemsSummary: View {
    @ObservedObject var itemManager: MenuBarItemManager
    @ObservedObject var imageCache: MenuBarItemImageCache

    let selection: Set<String>

    /// The currently selected items that exist in the menu bar.
    private var selectedItems: [MenuBarItem] {
        var seen = Set<String>()
        var results = [MenuBarItem]()
        for section in MenuBarSection.Name.allCases {
            for item in itemManager.itemCache.managedItems(for: section) {
                guard
                    let key = item.tag.automationKey,
                    selection.contains(key),
                    !seen.contains(key)
                else {
                    continue
                }
                seen.insert(key)
                results.append(item)
            }
        }
        return results
    }

    var body: some View {
        if selection.isEmpty {
            Text("No items selected")
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 4) {
                ForEach(selectedItems, id: \.windowID) { item in
                    ZStack {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.black.opacity(0.72))
                        if let captured = imageCache.images[item.windowID] {
                            Image(nsImage: captured.nsImage)
                                .resizable()
                                .scaledToFit()
                                .frame(height: 17)
                                .padding(.horizontal, 3)
                        }
                    }
                    .frame(width: 30, height: 22)
                    .help(item.displayName)
                }
                if selectedItems.count < selection.count {
                    Text("+\(selection.count - selectedItems.count) not running")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct AutomationItemPickerContent: View {
    @ObservedObject var itemManager: MenuBarItemManager
    @ObservedObject var imageCache: MenuBarItemImageCache
    @Binding var selection: Set<String>

    /// The current menu bar items that can be governed by a rule,
    /// deduplicated and sorted by display name.
    private var eligibleItems: [(key: String, item: MenuBarItem)] {
        var seen = Set<String>()
        var results = [(key: String, item: MenuBarItem)]()
        for section in MenuBarSection.Name.allCases {
            for item in itemManager.itemCache.managedItems(for: section) {
                guard
                    item.isMovable,
                    item.canBeHidden,
                    item.tag.namespace != .ice,
                    let key = item.tag.automationKey,
                    !seen.contains(key)
                else {
                    continue
                }
                seen.insert(key)
                results.append((key, item))
            }
        }
        return results.sorted {
            $0.item.displayName.localizedCaseInsensitiveCompare($1.item.displayName) == .orderedAscending
        }
    }

    private var unavailableSelectedKeys: [String] {
        let eligibleKeys = Set(eligibleItems.map(\.key))
        return selection.subtracting(eligibleKeys).sorted()
    }

    var body: some View {
        if eligibleItems.isEmpty {
            Text("No menu bar items found. Open the Menu Bar Layout pane to refresh the item list.")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Items managed by this rule:")
                    .foregroundStyle(.secondary)

                ForEach(eligibleItems, id: \.key) { entry in
                    Toggle(isOn: bindingForItem(withKey: entry.key)) {
                        HStack(spacing: 6) {
                            itemImageView(for: entry.item)
                            Text(entry.item.displayName)
                        }
                    }
                }

                if !unavailableSelectedKeys.isEmpty {
                    Divider()
                        .padding(.vertical, 4)
                    Text("Unavailable items")
                        .foregroundStyle(.secondary)
                    ForEach(unavailableSelectedKeys, id: \.self) { key in
                        Toggle(isOn: bindingForItem(withKey: key)) {
                            Text(displayName(forUnavailableKey: key))
                                .help(key.replacingOccurrences(of: "\u{1F}", with: " | "))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func itemImageView(for item: MenuBarItem) -> some View {
        // Menu bar item captures are rendered for the menu bar's dark
        // appearance, so draw them on a dark chip to keep them visible
        // against the settings window's light background.
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.black.opacity(0.72))
            if let captured = imageCache.images[item.windowID] {
                Image(nsImage: captured.nsImage)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 17)
                    .padding(.horizontal, 3)
            } else {
                Image(systemName: "square.dashed")
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .frame(width: 34, height: 22)
    }

    private func bindingForItem(withKey key: String) -> Binding<Bool> {
        Binding(
            get: { selection.contains(key) },
            set: { isSelected in
                if isSelected {
                    selection.insert(key)
                } else {
                    selection.remove(key)
                }
            }
        )
    }

    private func displayName(forUnavailableKey key: String) -> String {
        let components = key.split(separator: "\u{1F}", maxSplits: 1).map(String.init)
        guard let namespace = components.first else {
            return key
        }
        if components.count == 2, components[1] != "Item-0", !components[1].isEmpty {
            return "\(namespace) — \(components[1])"
        }
        return namespace
    }
}
