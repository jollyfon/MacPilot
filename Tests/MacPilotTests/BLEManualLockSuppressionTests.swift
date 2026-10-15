import AppKit
import CoreBluetooth
import Foundation
import Testing
@testable import MacPilot

@MainActor
struct BLEManualLockSuppressionTests {
    private let lockedNotification = Notification.Name("com.apple.screenIsLocked")

    private func makeModel(departures: ManualLockDepartureClock? = nil) -> (BLEUnlockModel, NotificationCenter, UUID) {
        let model = BLEUnlockModel(
            userActivityMonitor: BLEUserActivityMonitor(
                uptime: { departures?.now ?? ProcessInfo.processInfo.systemUptime }, observesEvents: false
            ),
            bluetoothScanner: ManualLockBluetoothScanner(),
            eventScriptRunner: { _ in }
        )
        let center = NotificationCenter()
        model.screenStateNotificationCenterOverride = center
        model.workspaceNotificationCenterOverride = NotificationCenter()
        model.heldBlankNotificationCenterOverride = NotificationCenter()
        model.displayUnavailableProbe = { false }
        model.screenLockStateProbe = { .locked }
        model.settings.isEnabled = true
        model.settings.lockRSSI = BLEUnlockModel.lockDisabled
        model.settings.unlockRSSI = -70
        if let departures {
            model.proximityTimeoutScheduler = { departures.schedule(after: $0, action: $1) }
        }
        model.startObservingSystemState()
        let phone = UUID()
        model.startMonitor(phone)
        return (model, center, phone)
    }

    @Test func systemLockCancelsAnAlreadyQueuedUnlockAndRejectsFreshSignal() {
        let (model, center, phone) = makeModel()
        defer { model.shutdown() }
        model.updateMonitoredPeripheral(-50, for: phone)
        #expect(model.isUnlockAttemptScheduled)

        center.post(name: lockedNotification, object: nil)

        #expect(!model.isUnlockAttemptScheduled)
        #expect(model.screenLockHistory.first?.lockSource == .manual)
        model.updateMonitoredPeripheral(-45, for: phone)
        #expect(!model.isUnlockAttemptScheduled)
    }

    @Test func duplicateSystemLockStillSuppressesUnlockWhenHistoryIsAlreadyOpen() {
        let (model, center, phone) = makeModel()
        defer { model.shutdown() }
        // History de-duplication must not short-circuit the safety policy.
        _ = model.settings.screenLockHistory.recordLock(at: Date(), source: .automatic)
        model.updateMonitoredPeripheral(-50, for: phone)
        #expect(model.isUnlockAttemptScheduled)

        center.post(name: lockedNotification, object: nil)
        center.post(name: lockedNotification, object: nil)
        model.updateMonitoredPeripheral(-45, for: phone)

        #expect(!model.isUnlockAttemptScheduled)
        #expect(model.screenLockHistory.count == 1)
    }

    @Test func signalLossAndReturnCannotClearAnyUserRequestedLock() {
        for source in [ScreenControlSource.localManual, .remoteExplicit] {
            let (model, center, phone) = makeModel()
            defer { model.shutdown() }
            // Attribution callback only: never invoke a real screen operation.
            model.screenControl.willLock?(source)
            center.post(name: lockedNotification, object: nil)
            model.updateMonitoredPeripheral(-50, for: phone)

            model.handleMonitoredSignalTimeout(for: phone)
            #expect(!model.presence)
            model.updateMonitoredPeripheral(-45, for: phone)

            #expect(model.presence)
            #expect(!model.isUnlockAttemptScheduled)
        }
    }

    @Test func systemLockSurvivesSignalTimeoutMonitoringRestartAndDisplayWake() {
        let (model, center, phone) = makeModel()
        defer { model.shutdown() }
        center.post(name: lockedNotification, object: nil)
        model.updateMonitoredPeripheral(-50, for: phone)
        model.handleMonitoredSignalTimeout(for: phone)
        model.startMonitor(phone)
        model.workspaceNotificationCenterOverride?.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        model.updateMonitoredPeripheral(-45, for: phone)

        #expect(!model.isUnlockAttemptScheduled)
    }

    @Test func proximityOwnedLockStillAllowsFreshSignalToUnlock() {
        let (model, center, phone) = makeModel()
        defer { model.shutdown() }
        model.screenControl.willLock?(.bleAutomatic)
        center.post(name: lockedNotification, object: nil)

        model.updateMonitoredPeripheral(-50, for: phone)

        #expect(model.screenLockHistory.first?.lockSource == .automatic)
        #expect(model.isUnlockAttemptScheduled)
    }

    @Test func confirmedManualUnlockRearmsProximityWithoutClaimingAnOldAutomaticRequest() {
        let (model, center, phone) = makeModel()
        defer { model.shutdown() }
        model.noteAutomaticUnlockRequest(at: Date().timeIntervalSince1970)
        center.post(name: lockedNotification, object: nil)
        model.screenLockStateProbe = { .unlocked }

        model.confirmAutomaticUnlock(source: "mocked manual unlock")

        #expect(model.screenLockHistory.first?.unlockSource == .manual)
        model.screenLockStateProbe = { .locked }
        model.screenControl.willLock?(.bleAutomatic)
        center.post(name: lockedNotification, object: nil)
        model.updateMonitoredPeripheral(-50, for: phone)
        #expect(model.isUnlockAttemptScheduled)
    }

    @Test func confirmedDepartureAndReturnRearmsSystemLocalAndRemoteManualLocks() throws {
        for source in [nil, ScreenControlSource.localManual, .remoteExplicit] {
            let departures = ManualLockDepartureClock()
            let (model, center, phone) = makeModel(departures: departures)
            defer { model.shutdown() }
            model.updateMonitoredPeripheral(-50, for: phone)
            if let source { model.screenControl.willLock?(source) }
            center.post(name: lockedNotification, object: nil)
            #expect(!model.isUnlockAttemptScheduled)

            for _ in 0..<5 { model.updateMonitoredPeripheral(-95, for: phone) }
            #expect(!model.isUnlockAttemptScheduled)
            let confirmDeparture = try #require(departures.actions.last)
            confirmDeparture()
            #expect(!model.presence)
            #expect(!model.isUnlockAttemptScheduled, "Departure rearms; only a later fresh close signal authorizes unlocking")

            model.updateMonitoredPeripheral(-45, for: phone)
            #expect(model.presence)
            #expect(model.isUnlockAttemptScheduled)
        }
    }

    @Test func departureCanBeConfirmedAfterRecoveryHasAlreadyClearedPresence() throws {
        let departures = ManualLockDepartureClock()
        let (model, center, phone) = makeModel(departures: departures)
        defer { model.shutdown() }
        center.post(name: lockedNotification, object: nil)
        model.handleMonitoredSignalTimeout(for: phone)
        #expect(!model.presence)

        // A new distant sample must start its own confirmation window even
        // though recovery previously set presence to false.
        model.updateMonitoredPeripheral(-95, for: phone)
        let confirmDeparture = try #require(departures.actions.last)
        confirmDeparture()
        model.updateMonitoredPeripheral(-45, for: phone)

        #expect(model.isUnlockAttemptScheduled)
    }

    @Test func briefWeakSignalCannotRearmAManualLock() throws {
        let departures = ManualLockDepartureClock()
        let (model, center, phone) = makeModel(departures: departures)
        defer { model.shutdown() }
        center.post(name: lockedNotification, object: nil)
        model.updateMonitoredPeripheral(-95, for: phone)
        let canceledDeparture = try #require(departures.actions.last)
        for _ in 0..<5 { model.updateMonitoredPeripheral(-45, for: phone) }

        // A canceled callback must not overwrite the recovered nearby state.
        canceledDeparture()
        model.updateMonitoredPeripheral(-45, for: phone)
        #expect(model.presence)
        #expect(!model.isUnlockAttemptScheduled)
    }

    @Test func anOldDepartureCannotClearANewerManualLock() throws {
        let departures = ManualLockDepartureClock()
        let (model, center, phone) = makeModel(departures: departures)
        defer { model.shutdown() }
        model.updateMonitoredPeripheral(-95, for: phone)
        let oldDeparture = try #require(departures.actions.last)
        center.post(name: lockedNotification, object: nil)

        oldDeparture()
        model.updateMonitoredPeripheral(-45, for: phone)

        #expect(model.presence)
        #expect(!model.isUnlockAttemptScheduled)
    }

    @Test func displaySleepAndSignalSilenceCannotTurnAnOldWeakSampleIntoADeparture() throws {
        for interruptWithSleep in [false, true] {
            let departures = ManualLockDepartureClock()
            let (model, center, phone) = makeModel(departures: departures)
            defer { model.shutdown() }
            center.post(name: lockedNotification, object: nil)
            model.updateMonitoredPeripheral(-95, for: phone)
            let oldDeparture = try #require(departures.actions.last)
            if interruptWithSleep {
                model.workspaceNotificationCenterOverride?.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
            } else {
                model.handleMonitoredSignalTimeout(for: phone)
            }

            oldDeparture()
            model.workspaceNotificationCenterOverride?.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
            model.updateMonitoredPeripheral(-45, for: phone)

            #expect(!model.isUnlockAttemptScheduled)
        }
    }

    @Test func oneDistantDeviceCannotRearmAnAnyDeviceLockWhileAnotherIsNearby() throws {
        let departures = ManualLockDepartureClock()
        let (model, center, phone) = makeModel(departures: departures)
        defer { model.shutdown() }
        let watch = UUID()
        model.settings.secondaryMonitoredDeviceUUID = watch.uuidString
        model.secondaryMonitoredUUID = watch
        model.settings.deviceRelation = .any
        model.startMonitor(phone)
        model.updateMonitoredPeripheral(-50, for: phone)
        model.updateMonitoredPeripheral(-50, for: watch)
        center.post(name: lockedNotification, object: nil)

        for _ in 0..<5 { model.updateMonitoredPeripheral(-95, for: phone) }
        let confirmPhoneDeparture = try #require(departures.actions.last)
        confirmPhoneDeparture()
        model.updateMonitoredPeripheral(-45, for: watch)

        #expect(model.presence)
        #expect(!model.isUnlockAttemptScheduled)

        for _ in 0..<5 { model.updateMonitoredPeripheral(-95, for: watch) }
        let confirmWatchDeparture = try #require(departures.actions.last)
        confirmWatchDeparture()
        #expect(!model.presence)
        model.updateMonitoredPeripheral(-45, for: phone)
        #expect(model.isUnlockAttemptScheduled)
    }

    @Test func aDelayedTimerCannotRearmFromAnExpiredWeakSample() throws {
        let departures = ManualLockDepartureClock()
        let (model, center, phone) = makeModel(departures: departures)
        defer { model.shutdown() }
        // Keep the independent idle policy from masking the lock decision.
        model.settings.lockRSSI = -80
        center.post(name: lockedNotification, object: nil)
        model.updateMonitoredPeripheral(-95, for: phone)
        let delayedDeparture = try #require(departures.actions.last)
        departures.now += TimeInterval(model.settings.signalTimeout) + 1

        delayedDeparture()
        model.updateMonitoredPeripheral(-45, for: phone)

        #expect(!model.activeConnectionsPaused)
        #expect(!model.isUnlockAttemptScheduled)
    }
}

@MainActor
private final class ManualLockDepartureClock {
    var now: TimeInterval = 100
    var actions: [@MainActor () -> Void] = []

    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) -> BackgroundTask {
        actions.append(action)
        // The test fires the production callback synchronously. No real screen
        // control, credential lookup or elapsed-time assertion is involved.
        return BackgroundTask.once(after: 3_600, action: {})
    }
}

@MainActor
private final class ManualLockBluetoothScanner: BluetoothScanning {
    var central: CBCentralManager?
    func createIfNeeded(delegate: CBCentralManagerDelegate) {}
    func startIfPoweredOn() -> Bool { true }
    func restartIfPoweredOn() -> Bool { true }
    func stop() {}
    func release() {}
}
