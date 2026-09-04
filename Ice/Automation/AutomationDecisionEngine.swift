//
//  AutomationDecisionEngine.swift
//  Ice
//

import Foundation

/// Pure decision helpers used by menu bar automation.
///
/// Keeping rule precedence and lifecycle decisions free of AppKit state makes
/// the most failure-prone automation transitions deterministic and testable.
enum AutomationDecisionEngine {
    /// Returns all item keys currently owned by an enabled rule.
    static func governedKeys(
        wifiRule: AutomationRule,
        powerRule: AutomationRule
    ) -> Set<String> {
        var keys = Set<String>()
        if wifiRule.isEnabled {
            keys.formUnion(wifiRule.itemKeys)
        }
        if powerRule.isEnabled {
            keys.formUnion(powerRule.itemKeys)
        }
        return keys
    }

    /// Computes the current section requested by the enabled rules.
    ///
    /// The power rule is applied last and therefore wins when both rules own
    /// the same item. Conditions that are not known yet produce no movement.
    static func desiredPlacements(
        wifiRule: AutomationRule,
        powerRule: AutomationRule,
        isWiFiConnected: Bool?,
        isOnExternalPower: Bool?
    ) -> [String: MenuBarSection.Name] {
        var desired = [String: MenuBarSection.Name]()

        func apply(rule: AutomationRule, conditionMet: Bool?) {
            guard rule.isEnabled, let conditionMet else {
                return
            }
            let shouldShow = switch rule.action {
            case .showWhenMet: conditionMet
            case .hideWhenMet: !conditionMet
            }
            for key in rule.itemKeys {
                desired[key] = shouldShow ? .visible : .hidden
            }
        }

        apply(rule: wifiRule, conditionMet: isWiFiConnected)
        apply(rule: powerRule, conditionMet: isOnExternalPower)
        return desired
    }

    /// Returns keys that were released by a rule configuration change.
    static func retiredKeys(
        previous: Set<String>,
        current: Set<String>
    ) -> Set<String> {
        previous.subtracting(current)
    }

    /// Resolves the section to restore when a rule releases an item.
    ///
    /// A remembered pre-rule section is preferred. The hidden section is the
    /// conservative fallback promised by the Automation settings UI.
    static func retirementTarget(
        for key: String,
        rememberedPlacements: [String: String]
    ) -> MenuBarSection.Name {
        switch rememberedPlacements[key] {
        case "visible": .visible
        case "alwaysHidden": .alwaysHidden
        default: .hidden
        }
    }
}
