import Foundation

/// Bounds the foreground-only BLE proof used to learn a paired iPhone's
/// peripheral identity. It never determines whether the device is nearby; BLE
/// Unlock still applies its own signal policy on the Mac.
enum RemoteBLEIdentityProbePolicy {
    /// The Mac discovers the phone in bounded attempts separated by an
    /// exponential backoff (up to minutes while no phone is advertising). A
    /// 12-second window regularly fell entirely inside a backoff interval, so
    /// the identity was never learned; 30 seconds lets one foreground probe
    /// overlap a realistic number of Mac scan attempts without advertising
    /// indefinitely.
    static let windowDuration: TimeInterval = 30

    static func shouldStart(
        isForeground: Bool,
        alreadyAttemptedThisForeground: Bool,
        hasAuthenticatedNetworkSession: Bool,
        serverSupportsLearning: Bool
    ) -> Bool {
        isForeground
            && !alreadyAttemptedThisForeground
            && hasAuthenticatedNetworkSession
            && serverSupportsLearning
    }

    static func shouldAcceptChannel(
        isForeground: Bool,
        isProbeWindowActive: Bool,
        hasAuthenticatedNetworkSession: Bool,
        serverSupportsLearning: Bool
    ) -> Bool {
        isForeground
            && isProbeWindowActive
            && hasAuthenticatedNetworkSession
            && serverSupportsLearning
    }
}
