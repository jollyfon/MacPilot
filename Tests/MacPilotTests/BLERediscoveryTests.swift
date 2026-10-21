import CoreBluetooth
import Foundation
import Testing
@testable import MacPilot

@MainActor
struct BLERediscoveryTests {
    @Test func aKnownButDisconnectedWatchStillNeedsAdvertisements() {
        #expect(!BLEScanPolicy.needsAdvertisements(connectionState: .connected, hasRSSIPoller: true))
        for state in [CBPeripheralState.disconnected, .connecting, .disconnecting] {
            #expect(BLEScanPolicy.needsAdvertisements(connectionState: state, hasRSSIPoller: true))
        }
        #expect(BLEScanPolicy.needsAdvertisements(connectionState: .connected, hasRSSIPoller: false))
        #expect(BLEScanPolicy.needsAdvertisements(connectionState: nil, hasRSSIPoller: false))
    }

    @Test func advertisementsRefreshPresenceEvenWhenAnActivePollerSurvivedDisconnection() throws {
        let h = Harness()
        defer { h.model.shutdown() }
        let runtime = try #require(h.model.runtime(for: h.phone))
        runtime.activeModeTimer = BackgroundTask.repeating(every: 3_600) {}
        h.model.receiveMonitoredAdvertisement(-50, for: h.phone)
        h.now += 30
        h.model.receiveMonitoredAdvertisement(-45, for: h.phone)
        #expect(runtime.lastRSSISampledAt == h.now)
        #expect(h.model.presence)
        #expect(h.locks.isEmpty)
    }

    @Test(arguments: [true, false])
    func eachLogicalDeviceIsRediscoveredEvenIfTheOtherIsFresh(phoneIsFresh: Bool) {
        let h = Harness()
        defer { h.model.shutdown() }
        h.model.receiveMonitoredAdvertisement(-50, for: phoneIsFresh ? h.phone : h.watch)
        h.model.evaluateMonitoringDiscovery()
        #expect(h.scanner.restarts == 1)
        h.model.evaluateMonitoringDiscovery()
        #expect(h.scanner.restarts == 1, "Missing devices cannot cause an unbounded scan restart loop")
        h.now += 10
        h.model.receiveMonitoredAdvertisement(-50, for: phoneIsFresh ? h.phone : h.watch)
        h.model.evaluateMonitoringDiscovery()
        #expect(h.scanner.restarts == 2)
        #expect(h.scanner.centralResets == 0)
    }

    @Test func healthyDevicesNeedNoDiscoveryAndAnUnknownAliasDoesNotCountAsAMissingDevice() {
        let h = Harness()
        defer { h.model.shutdown() }
        h.model.bindRemoteIdentity(primaryUUID: h.phone, clientID: "phone", keyFingerprint: "test")
        h.model.learnAuthenticatedBLEIdentity(clientID: "phone", keyFingerprint: "test", peripheralUUID: UUID())
        h.model.receiveMonitoredAdvertisement(-50, for: h.phone)
        h.model.receiveMonitoredAdvertisement(-50, for: h.watch)
        h.model.evaluateMonitoringDiscovery()
        #expect(h.scanner.restarts == 0)
    }

    @Test func twoSimultaneousTimeoutsCannotLockBeforeTheRediscoveryResultArrives() throws {
        let h = Harness()
        defer { h.model.shutdown() }
        h.model.receiveMonitoredAdvertisement(-50, for: h.phone)
        h.model.receiveMonitoredAdvertisement(-55, for: h.watch)
        h.now += 60
        h.model.handleMonitoredSignalTimeout(for: h.phone)
        h.model.handleMonitoredSignalTimeout(for: h.watch)
        #expect(h.locks.isEmpty)
        #expect(h.model.lastRSSI == nil, "Verification may retain a lock decision, never fresh unlock evidence")
        #expect(!h.model.isUnlockAttemptScheduled)
        #expect(h.scanner.restarts == 1)
        #expect(h.scanner.centralResets == 0)

        let phoneVerification = try #require(h.signalActions.dropLast().last)
        let watchVerification = try #require(h.signalActions.last)
        #expect(phoneVerification.delay == 240)
        #expect(watchVerification.delay == 240)
        h.now += 5
        h.model.receiveMonitoredAdvertisement(-52, for: h.watch)
        h.now += 235
        phoneVerification.action()
        watchVerification.action() // stale callback must not erase the new watch signal
        #expect(h.model.presence)
        #expect(h.model.lastRSSI == -52)
        #expect(h.locks.isEmpty)
        #expect(h.scanner.centralResets == 0)
    }

    @Test func genuinelySilentDevicesStillLockAfterOneBoundedVerification() throws {
        let h = Harness()
        defer { h.model.shutdown() }
        h.model.receiveMonitoredAdvertisement(-50, for: h.phone)
        h.model.receiveMonitoredAdvertisement(-50, for: h.watch)
        h.now += 60
        h.model.handleMonitoredSignalTimeout(for: h.phone)
        h.model.handleMonitoredSignalTimeout(for: h.watch)
        let confirmations = Array(h.signalActions.suffix(2))
        #expect(confirmations.map(\.delay) == [240, 240])
        #expect(h.locks.isEmpty)
        // A phone last heard nearby still has to disappear after one bounded
        // window; the rotation tolerance must never be open-ended.
        h.now += 240
        for confirmation in confirmations { confirmation.action() }
        #expect(!h.model.presence)
        #expect(h.model.lastRSSI == nil)
        #expect(h.locks == [.bleAutomatic])
        #expect(h.scanner.centralResets == 0)
    }

    @Test func nearbySignalLossAddsABoundedWindowButAFadingPhoneKeepsTheShortOne() {
        #expect(BLEScanPolicy.signalLossVerificationDelay(signalTimeout: 60, lastRSSI: -50) == 240)
        #expect(BLEScanPolicy.signalLossVerificationDelay(signalTimeout: 60, lastRSSI: -65) == 240)
        #expect(BLEScanPolicy.signalLossVerificationDelay(signalTimeout: 60, lastRSSI: -66) == 10)
        #expect(BLEScanPolicy.signalLossVerificationDelay(signalTimeout: 60, lastRSSI: -80) == 10)
        #expect(BLEScanPolicy.signalLossVerificationDelay(signalTimeout: 60, lastRSSI: nil) == 10)
        #expect(BLEScanPolicy.signalLossVerificationDelay(signalTimeout: 30, lastRSSI: -50) == 120)
        #expect(BLEScanPolicy.signalLossVerificationDelay(signalTimeout: 300, lastRSSI: -50) == 240)
    }

    @Test func repeatedRediscoveryDoesNotExtendTheConfiguredSignalDeadline() throws {
        let h = Harness()
        defer { h.model.shutdown() }
        h.model.receiveMonitoredAdvertisement(-50, for: h.phone)
        h.model.receiveMonitoredAdvertisement(-50, for: h.watch)
        let deadline = try #require(h.model.runtime(for: h.phone)?.signalTimeoutDeadline)
        for _ in 0..<5 {
            h.now += 10
            h.model.evaluateMonitoringDiscovery()
            #expect(h.model.runtime(for: h.phone)?.signalTimeoutDeadline == deadline)
        }
        #expect(h.scanner.restarts == 5)
        #expect(h.locks.isEmpty)
    }

    @Test func renewedSignalDeadlineReusesTimerAndEarlyWakeWaitsForLatestDeadline() throws {
        let h = Harness(includeSecondaryDevice: false)
        defer { h.model.shutdown() }
        h.model.receiveMonitoredAdvertisement(-50, for: h.phone)
        let runtime = try #require(h.model.runtime(for: h.phone))
        let initialAction = try #require(h.signalActions.last)
        let initialActionCount = h.signalActions.count
        let initialScheduledDeadline = try #require(runtime.signalTimerScheduledDeadline)

        for _ in 0..<5 {
            h.now += 5
            h.model.receiveMonitoredAdvertisement(-50, for: h.phone)
        }

        let renewedDeadline = try #require(runtime.signalTimeoutDeadline)
        #expect(renewedDeadline > initialScheduledDeadline)
        #expect(h.signalActions.count == initialActionCount, "Fresh RSSI renews the deadline without replacing the armed timer")

        h.now = initialScheduledDeadline
        initialAction.action()
        #expect(h.signalActions.count == initialActionCount + 1)
        let renewedAction = try #require(h.signalActions.last)
        #expect(runtime.signalTimerScheduledDeadline == renewedDeadline)
        #expect(renewedAction.delay == renewedDeadline - h.now)
        #expect(!runtime.verifyingSignalLoss, "An early timer wake must not start loss verification")

        let actionCountAfterRearm = h.signalActions.count
        initialAction.action()
        #expect(h.signalActions.count == actionCountAfterRearm, "A duplicate callback from the consumed arm must be ignored")

        h.now = renewedDeadline
        renewedAction.action()
        #expect(runtime.verifyingSignalLoss)
        #expect(h.locks.isEmpty)
        #expect(h.signalActions.last?.delay == 240, "A near last sample still enters a bounded rediscovery check")
    }

    @Test func shorteningSignalDeadlineRearmsEarlierAndRejectsTheOldCallback() throws {
        let h = Harness(includeSecondaryDevice: false)
        defer { h.model.shutdown() }
        h.model.receiveMonitoredAdvertisement(-50, for: h.phone)
        let runtime = try #require(h.model.runtime(for: h.phone))
        let oldAction = try #require(h.signalActions.last)
        let oldActionCount = h.signalActions.count
        let oldScheduledDeadline = try #require(runtime.signalTimerScheduledDeadline)

        h.now += 10
        h.model.settings.signalTimeout = 20
        h.model.receiveMonitoredAdvertisement(-50, for: h.phone)

        let shortenedDeadline = try #require(runtime.signalTimeoutDeadline)
        #expect(shortenedDeadline < oldScheduledDeadline)
        #expect(h.signalActions.count == oldActionCount + 1)
        let shortenedAction = try #require(h.signalActions.last)
        #expect(runtime.signalTimerScheduledDeadline == shortenedDeadline)

        h.now = shortenedDeadline
        oldAction.action()
        #expect(!runtime.verifyingSignalLoss, "The cancelled later arm cannot consume the shortened deadline")

        shortenedAction.action()
        #expect(runtime.verifyingSignalLoss)
        #expect(h.locks.isEmpty)
    }

    @Test func invalidatingSignalTimerMakesItsPendingCallbackStale() throws {
        let h = Harness(includeSecondaryDevice: false)
        defer { h.model.shutdown() }
        h.model.receiveMonitoredAdvertisement(-50, for: h.phone)
        let runtime = try #require(h.model.runtime(for: h.phone))
        let pendingAction = try #require(h.signalActions.last)

        runtime.invalidateTimers()
        let invalidatedGeneration = runtime.signalTimerGeneration
        h.now += 100
        pendingAction.action()

        #expect(runtime.signalTimerGeneration == invalidatedGeneration)
        #expect(runtime.signalTimeoutDeadline == nil)
        #expect(runtime.signalTimer == nil)
        #expect(h.locks.isEmpty)
    }

    @Test func aFreshWatchPreventsLockWhenThePhoneReallyStopsResponding() throws {
        let h = Harness()
        defer { h.model.shutdown() }
        h.model.receiveMonitoredAdvertisement(-50, for: h.phone)
        h.model.receiveMonitoredAdvertisement(-50, for: h.watch)
        h.now += 60
        h.model.handleMonitoredSignalTimeout(for: h.phone)
        let confirmation = try #require(h.signalActions.last)
        h.model.receiveMonitoredAdvertisement(-45, for: h.watch)
        h.now += 240
        confirmation.action()
        #expect(h.model.presence)
        #expect(h.locks.isEmpty)
    }

    @Test func allDeviceModeStillRequiresBothDevicesAfterVerification() throws {
        let h = Harness()
        defer { h.model.shutdown() }
        h.model.settings.deviceRelation = .all
        h.model.receiveMonitoredAdvertisement(-50, for: h.phone)
        h.model.receiveMonitoredAdvertisement(-50, for: h.watch)
        h.now += 60
        h.model.handleMonitoredSignalTimeout(for: h.phone)
        let confirmation = try #require(h.signalActions.last)
        h.model.receiveMonitoredAdvertisement(-45, for: h.watch)
        h.now += 240
        confirmation.action()
        #expect(!h.model.presence)
        #expect(h.locks == [.bleAutomatic])
    }

    @Test func weakSignalDepartureKeepsItsOriginalDelayAndDeviceRelationship() {
        let h = Harness()
        defer { h.model.shutdown() }
        h.model.receiveMonitoredAdvertisement(-50, for: h.phone)
        h.model.receiveMonitoredAdvertisement(-50, for: h.watch)
        for uuid in [h.phone, h.watch] {
            for _ in 0..<5 { h.model.receiveMonitoredAdvertisement(-95, for: uuid) }
            #expect(h.proximityActions.last?.delay == 5)
            h.proximityActions.last?.action()
            if uuid == h.phone { #expect(h.locks.isEmpty) }
        }
        #expect(h.locks == [.bleAutomatic])
    }

    @Test func overdueWeakSignalCallbacksCannotLockUsingExpiredSamples() {
        let h = Harness()
        defer { h.model.shutdown() }
        h.model.receiveMonitoredAdvertisement(-50, for: h.phone)
        h.model.receiveMonitoredAdvertisement(-50, for: h.watch)
        for uuid in [h.phone, h.watch] {
            for _ in 0..<5 { h.model.receiveMonitoredAdvertisement(-95, for: uuid) }
        }
        h.now += 61
        for callback in h.proximityActions { callback.action() }
        #expect(h.locks.isEmpty, "An overdue weak-signal timer must use signal-loss verification instead")
        #expect(h.model.presence)
    }

    @Test func shutdownStopsTheDiscoveryTimerAndDoesNotRestartTheRadio() {
        let h = Harness()
        h.model.shutdown()
        h.now += 100
        h.model.evaluateMonitoringDiscovery()
        #expect(h.scanner.restarts == 0)
        #expect(h.model.diagnosticTaskCount == 0)
    }

    @Test func addressRotationHandsOverTheLiveObservationAndRetiresTheOldTimer() throws {
        let h = Harness(includeSecondaryDevice: false)
        defer { h.model.shutdown() }
        h.model.bindRemoteIdentity(primaryUUID: h.phone, clientID: "phone", keyFingerprint: "test")
        let firstAlias = UUID()
        h.model.learnAuthenticatedBLEIdentity(
            clientID: "phone", keyFingerprint: "test", peripheralUUID: firstAlias,
            now: Date(timeIntervalSince1970: h.now)
        )
        h.model.receiveMonitoredAdvertisement(-50, for: firstAlias)
        #expect(h.model.presence)

        h.now += 900
        let rotatedAlias = UUID()
        h.model.learnAuthenticatedBLEIdentity(
            clientID: "phone", keyFingerprint: "test", peripheralUUID: rotatedAlias,
            now: Date(timeIntervalSince1970: h.now)
        )
        #expect(h.model.runtime(for: firstAlias) == nil, "A retired address must not keep a runtime or signal timer")
        let rotatedRuntime = try #require(h.model.runtime(for: rotatedAlias))
        #expect(rotatedRuntime.presence, "Rotation hands over the observation instead of looking like a departure")
        #expect(rotatedRuntime.lastRSSI == -50)
        #expect(h.model.presence)
        #expect(h.locks.isEmpty)

        h.now += 900
        h.model.learnAuthenticatedBLEIdentity(
            clientID: "phone", keyFingerprint: "test", peripheralUUID: firstAlias,
            now: Date(timeIntervalSince1970: h.now)
        )
        #expect(h.model.runtime(for: rotatedAlias) == nil)
        #expect(h.model.runtime(for: firstAlias)?.presence == true, "A returning address is promoted without a lock")
        #expect(h.model.presence)
        #expect(h.locks.isEmpty)
    }

    @Test func repeatedRotationsLeaveOneAliasRuntimePerLogicalDevice() throws {
        let h = Harness(includeSecondaryDevice: false)
        defer { h.model.shutdown() }
        h.model.bindRemoteIdentity(primaryUUID: h.phone, clientID: "phone", keyFingerprint: "test")
        var aliases: [UUID] = []
        for _ in 0..<8 {
            h.now += 120
            let alias = UUID()
            aliases.append(alias)
            h.model.learnAuthenticatedBLEIdentity(
                clientID: "phone", keyFingerprint: "test", peripheralUUID: alias,
                now: Date(timeIntervalSince1970: h.now)
            )
        }
        let current = try #require(aliases.last)
        #expect(h.model.runtime(for: current) != nil)
        for retired in aliases.dropLast() {
            #expect(h.model.runtime(for: retired) == nil)
        }
        #expect(h.model.runtime(for: h.phone) != nil, "The selected primary stays monitored for devices that do not rotate")
    }

    @MainActor
    private final class Harness {
        var now: TimeInterval = 100
        let phone = UUID()
        let watch = UUID()
        let scanner = Scanner()
        var model: BLEUnlockModel!
        var locks: [ScreenControlSource] = []
        var signalActions: [(delay: TimeInterval, action: @MainActor () -> Void)] = []
        var proximityActions: [(delay: TimeInterval, action: @MainActor () -> Void)] = []

        init(includeSecondaryDevice: Bool = true) {
            model = BLEUnlockModel(
                userActivityMonitor: BLEUserActivityMonitor(uptime: { [weak self] in self?.now ?? 0 }, observesEvents: false),
                bluetoothScanner: scanner,
                eventScriptRunner: { _ in }
            )
            model.displayUnavailableProbe = { false }
            model.screenLockStateProbe = { .unlocked }
            model.lockScreenOperation = { [weak self] in self?.locks.append($0) }
            model.settings.isEnabled = true
            model.settings.deviceRelation = .any
            model.settings.signalTimeout = 60
            model.settings.proximityTimeout = 5
            model.settings.lockRSSI = -80
            model.settings.unlockRSSI = BLEUnlockModel.unlockDisabled
            model.settings.pauseNowPlaying = false
            model.signalTimeoutScheduler = { [weak self] delay, action in
                self?.signalActions.append((delay, action))
                return BackgroundTask.once(after: 3_600) {}
            }
            model.proximityTimeoutScheduler = { [weak self] delay, action in
                self?.proximityActions.append((delay, action))
                return BackgroundTask.once(after: 3_600) {}
            }
            if includeSecondaryDevice {
                model.secondaryMonitoredUUID = watch
            }
            model.startMonitor(phone)
        }
    }

    @MainActor
    private final class Scanner: BluetoothScanning {
        var central: CBCentralManager? {
            get { nil }
            set { centralResets += 1 }
        }
        var centralResets = 0
        var restarts = 0
        func createIfNeeded(delegate: CBCentralManagerDelegate) {}
        func startIfPoweredOn() -> Bool { true }
        func restartIfPoweredOn() -> Bool { restarts += 1; return true }
        func stop() {}
        func release() {}
    }
}
