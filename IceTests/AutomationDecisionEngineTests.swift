//
//  AutomationDecisionEngineTests.swift
//  IceTests
//

import XCTest
@testable import Ice

final class AutomationDecisionEngineTests: XCTestCase {
    func testGovernedKeysOnlyIncludesEnabledRules() {
        let wifiRule = rule(enabled: false, keys: ["wifi"])
        let powerRule = rule(enabled: true, keys: ["power", "shared"])

        XCTAssertEqual(
            AutomationDecisionEngine.governedKeys(
                wifiRule: wifiRule,
                powerRule: powerRule
            ),
            ["power", "shared"]
        )
    }

    func testPowerRuleWinsWhenBothRulesOwnAnItem() {
        let wifiRule = rule(
            enabled: true,
            action: .showWhenMet,
            keys: ["shared"]
        )
        let powerRule = rule(
            enabled: true,
            action: .hideWhenMet,
            keys: ["shared"]
        )

        let desired = AutomationDecisionEngine.desiredPlacements(
            wifiRule: wifiRule,
            powerRule: powerRule,
            isWiFiConnected: true,
            isOnExternalPower: true
        )

        XCTAssertEqual(desired["shared"]?.logString, "hidden section")
    }

    func testUnknownConditionDoesNotMoveRuleItems() {
        let wifiRule = rule(enabled: true, keys: ["wifi"])

        let desired = AutomationDecisionEngine.desiredPlacements(
            wifiRule: wifiRule,
            powerRule: AutomationRule(),
            isWiFiConnected: nil,
            isOnExternalPower: nil
        )

        XCTAssertTrue(desired.isEmpty)
    }

    func testRetiredKeysOnlyReturnsReleasedItems() {
        XCTAssertEqual(
            AutomationDecisionEngine.retiredKeys(
                previous: ["kept", "released"],
                current: ["kept", "new"]
            ),
            ["released"]
        )
    }

    func testRetirementUsesRememberedSectionAndSafeFallback() {
        let remembered = [
            "visible": "visible",
            "always": "alwaysHidden",
            "invalid": "somethingElse",
        ]

        XCTAssertEqual(
            AutomationDecisionEngine.retirementTarget(
                for: "visible",
                rememberedPlacements: remembered
            ).logString,
            "visible section"
        )
        XCTAssertEqual(
            AutomationDecisionEngine.retirementTarget(
                for: "always",
                rememberedPlacements: remembered
            ).logString,
            "always-hidden section"
        )
        XCTAssertEqual(
            AutomationDecisionEngine.retirementTarget(
                for: "invalid",
                rememberedPlacements: remembered
            ).logString,
            "hidden section"
        )
        XCTAssertEqual(
            AutomationDecisionEngine.retirementTarget(
                for: "missing",
                rememberedPlacements: remembered
            ).logString,
            "hidden section"
        )
    }

    private func rule(
        enabled: Bool,
        action: AutomationRule.Action = .showWhenMet,
        keys: Set<String>
    ) -> AutomationRule {
        var rule = AutomationRule()
        rule.isEnabled = enabled
        rule.action = action
        rule.itemKeys = keys
        return rule
    }
}
