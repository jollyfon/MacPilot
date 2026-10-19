import Foundation

/// Decides whether the phone publishes its BLE peripheral.
///
/// The advertisement is what the Mac's BLE Unlock scanner rediscovers after a
/// link drop, so it has to outlive the foreground whenever a paired Mac holds a
/// BLE Unlock binding for this phone. In every other case it stays bounded:
/// only while the app is in the foreground and Bluetooth can still improve the
/// session, or during the short identity probe.
enum RemoteBLEAdvertisingPolicy {
    static func shouldAdvertise(
        isForeground: Bool,
        wantsProximity: Bool,
        isIdentityProbeActive: Bool,
        hasManualTarget: Bool,
        bluetoothIsNeededForRace: Bool,
        keepsActiveBLESession: Bool
    ) -> Bool {
        // Stopping the peripheral while an L2CAP channel carries the control
        // session would close that session with it.
        if keepsActiveBLESession { return true }
        guard !hasManualTarget else { return false }
        if wantsProximity { return true }
        guard isForeground else { return false }
        return bluetoothIsNeededForRace || isIdentityProbeActive
    }
}
