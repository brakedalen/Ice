//
//  AutomationSettings.swift
//  Ice
//

import Combine
import Foundation
import OSLog

// MARK: - AutomationRule

/// A rule that shows or hides a set of menu bar items based on a
/// system condition.
struct AutomationRule: Codable, Hashable {
    /// The action a rule performs when its condition is met.
    enum Action: Int, Codable, CaseIterable, Identifiable {
        /// Show the items when the condition is met, hide them when not.
        case showWhenMet = 0
        /// Hide the items when the condition is met, show them when not.
        case hideWhenMet = 1

        var id: Int { rawValue }
    }

    /// Whether the rule is active.
    var isEnabled = false

    /// The action to perform when the rule's condition is met.
    var action: Action = .showWhenMet

    /// Encoded tag keys for the items the rule manages.
    var itemKeys: Set<String> = []
}

// MARK: - AutomationSettings

/// Model for the app's Automation settings.
@MainActor
final class AutomationSettings: ObservableObject {
    /// A Boolean value that indicates whether Ice should remember which
    /// section each menu bar item belongs to and restore items that
    /// reappear in the wrong section (for example, after apps like
    /// OneDrive recreate their menu bar item on login).
    @Published var rememberItemPositions = true

    /// The rule tied to Wi-Fi connectivity.
    @Published var wifiRule = AutomationRule()

    /// The rule tied to external power.
    @Published var powerRule = AutomationRule()

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// The shared app state.
    private(set) weak var appState: AppState?

    private let logger = Logger(category: "AutomationSettings")

    /// Performs the initial setup of the model.
    func performSetup(with appState: AppState) {
        self.appState = appState
        loadInitialState()
        configureCancellables()
    }

    /// Loads the model's initial state.
    private func loadInitialState() {
        Defaults.ifPresent(key: .automationRememberItemPositions, assign: &rememberItemPositions)

        if let rule = decodeRule(forKey: .automationWifiRule) {
            wifiRule = rule
        }
        if let rule = decodeRule(forKey: .automationPowerRule) {
            powerRule = rule
        }
    }

    private func decodeRule(forKey key: Defaults.Key) -> AutomationRule? {
        guard let data = Defaults.data(forKey: key) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(AutomationRule.self, from: data)
        } catch {
            logger.error("Failed to decode automation rule: \(error, privacy: .public)")
            return nil
        }
    }

    private func encodeAndStore(_ rule: AutomationRule, forKey key: Defaults.Key) {
        do {
            let data = try JSONEncoder().encode(rule)
            Defaults.set(data, forKey: key)
        } catch {
            logger.error("Failed to encode automation rule: \(error, privacy: .public)")
        }
    }

    /// Configures the internal observers for the model.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        $rememberItemPositions
            .receive(on: DispatchQueue.main)
            .sink { remember in
                Defaults.set(remember, forKey: .automationRememberItemPositions)
            }
            .store(in: &c)

        $wifiRule
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rule in
                self?.encodeAndStore(rule, forKey: .automationWifiRule)
            }
            .store(in: &c)

        $powerRule
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rule in
                self?.encodeAndStore(rule, forKey: .automationPowerRule)
            }
            .store(in: &c)

        cancellables = c
    }
}
