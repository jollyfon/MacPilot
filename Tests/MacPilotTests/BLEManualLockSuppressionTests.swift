import AppKit
import CoreBluetooth
import Foundation
import Testing
@testable import MacPilot

@MainActor
struct BLEManualLockSuppressionTests {
    private let lockedNotification = Notification.Name("com.apple.screenIsLocked")

    private func makeModel() -> (BLEUnlockModel, NotificationCenter, UUID) {
        let model = BLEUnlockModel(
            userActivityMonitor: BLEUserActivityMonitor(observesEvents: false),
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
