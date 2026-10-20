import Foundation
import Testing
@testable import MacPilot

@Suite("BLE presence authentication")
struct BLEPresenceAuthenticationTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("an address that is already monitored is never challenged")
    func monitoredAddressesAreSkipped() {
        #expect(!BLEPresenceAuthenticationPolicy.shouldAttempt(
            isMonitored: true,
            hasBindings: true,
            hasMacIdentity: true,
            lastAttemptAt: nil,
            now: now
        ))
    }

    @Test("nothing is challenged without a binding or a Mac identity")
    func configurationIsRequired() {
        #expect(!BLEPresenceAuthenticationPolicy.shouldAttempt(
            isMonitored: false,
            hasBindings: false,
            hasMacIdentity: true,
            lastAttemptAt: nil,
            now: now
        ))
        #expect(!BLEPresenceAuthenticationPolicy.shouldAttempt(
            isMonitored: false,
            hasBindings: true,
            hasMacIdentity: false,
            lastAttemptAt: nil,
            now: now
        ))
    }

    @Test("a new address is challenged immediately")
    func newAddressesAreChallenged() {
        #expect(BLEPresenceAuthenticationPolicy.shouldAttempt(
            isMonitored: false,
            hasBindings: true,
            hasMacIdentity: true,
            lastAttemptAt: nil,
            now: now
        ))
    }

    @Test("a rejected address waits out the retry interval")
    func rejectedAddressesAreRetriedAfterTheInterval() {
        let policy = BLEPresenceAuthenticationPolicy.retryInterval
        #expect(!BLEPresenceAuthenticationPolicy.shouldAttempt(
            isMonitored: false,
            hasBindings: true,
            hasMacIdentity: true,
            lastAttemptAt: now.addingTimeInterval(-policy + 1),
            now: now
        ))
        #expect(BLEPresenceAuthenticationPolicy.shouldAttempt(
            isMonitored: false,
            hasBindings: true,
            hasMacIdentity: true,
            lastAttemptAt: now.addingTimeInterval(-policy),
            now: now
        ))
    }

    @Test("a clock that moved backwards cannot force a reconnect loop")
    func futureAttemptTimestampsDoNotAuthorize() {
        #expect(!BLEPresenceAuthenticationPolicy.shouldAttempt(
            isMonitored: false,
            hasBindings: true,
            hasMacIdentity: true,
            lastAttemptAt: now.addingTimeInterval(60),
            now: now
        ))
    }
}
