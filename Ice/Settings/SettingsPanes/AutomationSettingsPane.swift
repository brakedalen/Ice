//
//  AutomationSettingsPane.swift
//  Ice
//

import SwiftUI

struct AutomationSettingsPane: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var settings: AutomationSettings
    @ObservedObject var monitor: SystemStateMonitor

    var body: some View {
        IceForm {
            IceSection("Item Positions") {
                rememberItemPositions
            }
            IceSection("Wi-Fi Rule") {
                AutomationRuleView(
                    rule: $settings.wifiRule,
                    conditionName: "connected to Wi-Fi",
                    statusText: wifiStatusText
                )
            }
            IceSection("Power Rule") {
                AutomationRuleView(
                    rule: $settings.powerRule,
                    conditionName: "connected to power",
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
}

// MARK: - AutomationRuleView

private struct AutomationRuleView: View {
    @Binding var rule: AutomationRule
    let conditionName: String
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
                "Action",
                selection: $rule.action
            ) {
                Text("Show selected items when \(conditionName)")
                    .tag(AutomationRule.Action.showWhenMet)
                Text("Hide selected items when \(conditionName)")
                    .tag(AutomationRule.Action.hideWhenMet)
            }
            .annotation("Items move to the hidden section when they are not shown.")

            AutomationItemPicker(selection: $rule.itemKeys)
        }
    }
}

// MARK: - AutomationItemPicker

private struct AutomationItemPicker: View {
    @EnvironmentObject var appState: AppState
    @Binding var selection: Set<String>

    var body: some View {
        AutomationItemPickerContent(
            itemManager: appState.itemManager,
            imageCache: appState.imageCache,
            selection: $selection
        )
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
            }
        }
    }

    @ViewBuilder
    private func itemImageView(for item: MenuBarItem) -> some View {
        if let captured = imageCache.images[item.tag] {
            Image(nsImage: captured.nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 18)
        } else {
            Image(systemName: "square.dashed")
                .frame(height: 18)
        }
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
}
