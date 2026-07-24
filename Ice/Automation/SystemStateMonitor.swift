//
//  SystemStateMonitor.swift
//  Ice
//

import Combine
import Foundation
import OSLog
import IOKit.ps
import Network

/// Monitors system state used by automation rules.
///
/// Both signals are passive, event-driven observers built on stable
/// system frameworks that require no special permissions:
///
/// - Wi-Fi connectivity uses `NWPathMonitor` from the Network framework.
/// - External power uses IOKit power source notifications, the same
///   mechanism the system's own battery indicator relies on.
@MainActor
final class SystemStateMonitor: ObservableObject {
    /// Whether the system currently has a satisfied Wi-Fi network path.
    /// `nil` until the first reading arrives.
    @Published private(set) var isWiFiConnected: Bool?

    /// Whether the system is currently drawing power from an external
    /// source (power adapter or UPS). `nil` until the first reading.
    @Published private(set) var isOnExternalPower: Bool?

    private let pathMonitor = NWPathMonitor(requiredInterfaceType: .wifi)

    private let pathMonitorQueue = DispatchQueue(label: "SystemStateMonitor.wifi", qos: .utility)

    private var powerRunLoopSource: CFRunLoopSource?

    private var isStarted = false

    private let logger = Logger(category: "SystemStateMonitor")

    /// Starts monitoring. Safe to call more than once.
    func start() {
        guard !isStarted else {
            return
        }
        isStarted = true

        startWiFiMonitor()
        startPowerMonitor()
    }

    // MARK: Wi-Fi

    private func startWiFiMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { @MainActor in
                guard let self else {
                    return
                }
                if self.isWiFiConnected != connected {
                    self.logger.info("Wi-Fi connectivity changed: \(connected, privacy: .public)")
                }
                self.isWiFiConnected = connected
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    // MARK: Power

    private func startPowerMonitor() {
        refreshPowerState()

        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else {
                return
            }
            let monitor = Unmanaged<SystemStateMonitor>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                monitor.refreshPowerState()
            }
        }

        guard let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() else {
            // Extremely unlikely. Fall back to a slow poll so the feature
            // keeps working rather than silently dying.
            logger.error("Failed to create power source run loop source, falling back to polling")
            Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshPowerState()
                }
            }
            return
        }

        powerRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    private func refreshPowerState() {
        let onExternalPower: Bool = {
            // Get rule: the returned CFString is not owned by the caller.
            guard let type = IOPSGetProvidingPowerSourceType(nil)?.takeUnretainedValue() as String? else {
                // If the power source type cannot be read (e.g. desktop Macs
                // without a battery may have no power source entries), treat
                // the machine as externally powered.
                return true
            }
            return type != kIOPMBatteryPowerKey
        }()

        if isOnExternalPower != onExternalPower {
            logger.info("External power changed: \(onExternalPower, privacy: .public)")
        }
        isOnExternalPower = onExternalPower
    }
}
