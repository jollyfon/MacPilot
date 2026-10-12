import AppKit
import CoreBluetooth
import Foundation
import Testing
@testable import MacPilot

@MainActor
struct BLEMonitoringRestorationTests {
    @Test func aWakeNotificationCannotAuthorizeUnlockBeforeAnyPhoneSignal() {
        let model = BLEUnlockModel(
            userActivityMonitor: BLEUserActivityMonitor(observesEvents: false),
            bluetoothScanner: RecordingBluetoothScanner()
        )
        defer { model.shutdown() }
        let center = NotificationCenter()
        model.workspaceNotificationCenterOverride = center
        model.displayUnavailableProbe = { false }
        model.screenLockStateProbe = { .locked }
        model.settings.isEnabled = true
        model.settings.lockRSSI = BLEUnlockModel.lockDisabled
        model.settings.unlockRSSI = -70
        model.startObservingSystemState()
        model.startMonitor(UUID())

        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)

        #expect(model.lastRSSI == nil)
        #expect(!model.isUnlockAttemptScheduled, "A bound phone without a fresh signal must not authorize a password attempt")
    }

    @Test func firstFreshNearbySignalCanUnlockASingleBoundPhoneWithoutAPresenceEdge() {
        let model = BLEUnlockModel(
            userActivityMonitor: BLEUserActivityMonitor(observesEvents: false),
            bluetoothScanner: RecordingBluetoothScanner()
        )
        defer { model.shutdown() }
        model.displayUnavailableProbe = { false }
        model.screenLockStateProbe = { .locked }
        model.settings.isEnabled = true
        model.settings.lockRSSI = BLEUnlockModel.lockDisabled
        model.settings.unlockRSSI = -70
        let phone = UUID()
        model.startMonitor(phone)
        #expect(!model.isUnlockAttemptScheduled, "Binding alone cannot authorize typing")

        model.updateMonitoredPeripheral(-50, for: phone)

        #expect(model.isUnlockAttemptScheduled, "A fresh close sample must trigger unlock even if presence was already true")
    }

    @Test func freshSignalCannotUndoAnExplicitManualOrRemoteLock() {
        for source in [ScreenControlSource.localManual, .remoteExplicit] {
            let model = BLEUnlockModel(
                userActivityMonitor: BLEUserActivityMonitor(observesEvents: false),
                bluetoothScanner: RecordingBluetoothScanner()
            )
            defer { model.shutdown() }
            model.displayUnavailableProbe = { false }
            model.screenLockStateProbe = { .locked }
            model.settings.isEnabled = true
            model.settings.lockRSSI = BLEUnlockModel.lockDisabled
            model.settings.unlockRSSI = -70
            let phone = UUID()
            model.startMonitor(phone)
            // Invoke attribution only, without locking a screen or posting keys.
            model.screenControl.willLock?(source)
            model.updateMonitoredPeripheral(-50, for: phone)
            #expect(!model.isUnlockAttemptScheduled)
        }
    }

    @Test func anAlreadyNearbyPhoneCanTriggerUnlockAfterTheSessionLocks() {
        var state = BLEScreenLockState.unlocked
        let model = BLEUnlockModel(
            userActivityMonitor: BLEUserActivityMonitor(observesEvents: false),
            bluetoothScanner: RecordingBluetoothScanner()
        )
        defer { model.shutdown() }
        model.displayUnavailableProbe = { false }
        model.screenLockStateProbe = { state }
        model.settings.isEnabled = true
        model.settings.lockRSSI = BLEUnlockModel.lockDisabled
        model.settings.unlockRSSI = -70
        let phone = UUID()
        model.startMonitor(phone)
        model.updateMonitoredPeripheral(-50, for: phone)
        #expect(model.presence)
        #expect(!model.isUnlockAttemptScheduled)

        state = .locked
        model.updateMonitoredPeripheral(-50, for: phone)

        #expect(model.isUnlockAttemptScheduled, "Unlock must not require the phone to leave and return after locking")
    }

    @Test func bindingAndAWeakOrUnlockedSampleDoNotAuthorizeUnlock() {
        for state in [BLEScreenLockState.locked, .unlocked, .unknown] {
            let model = BLEUnlockModel(
                userActivityMonitor: BLEUserActivityMonitor(observesEvents: false),
                bluetoothScanner: RecordingBluetoothScanner()
            )
            defer { model.shutdown() }
            model.displayUnavailableProbe = { false }
            model.screenLockStateProbe = { state }
            model.settings.isEnabled = true
            model.settings.lockRSSI = BLEUnlockModel.lockDisabled
            model.settings.unlockRSSI = -70
            let phone = UUID()
            model.startMonitor(phone)
            #expect(!model.isUnlockAttemptScheduled)
            model.updateMonitoredPeripheral(state == .locked ? -90 : -50, for: phone)
            #expect(!model.isUnlockAttemptScheduled)
        }
    }

    @Test func freshSignalAfterTenSecondsOfLockedWakeStillSchedulesUnlock() {
        var now: TimeInterval = 100
        let activity = BLEUserActivityMonitor(uptime: { now }, observesEvents: false)
        let model = BLEUnlockModel(userActivityMonitor: activity, bluetoothScanner: RecordingBluetoothScanner())
        defer { model.shutdown() }
        let center = NotificationCenter()
        model.workspaceNotificationCenterOverride = center
        model.displayUnavailableProbe = { false }
        model.screenLockStateProbe = { .locked }
        model.settings.isEnabled = true
        model.settings.lockRSSI = BLEUnlockModel.lockDisabled
        model.settings.unlockRSSI = -70
        model.startObservingSystemState()
        let phone = UUID()
        model.startMonitor(phone)
        now = 131
        model.evaluateUserActivityPolicy()
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        #expect(!model.presence, "Wake requires a fresh signal")

        now = 142
        model.evaluateUserActivityPolicy()
        model.updateMonitoredPeripheral(-50, for: phone)

        #expect(!model.activeConnectionsPaused, "The lock screen cannot rely on NSEvent input to keep reconnecting")
        #expect(model.isUnlockAttemptScheduled, "The ten-second discovery deadline must not cancel later unlock retries")
    }

    @Test func lockedWakeRecoveryExpiresAndDuplicateWakesCannotExtendIt() {
        var now: TimeInterval = 100
        let activity = BLEUserActivityMonitor(uptime: { now }, observesEvents: false)
        let model = BLEUnlockModel(userActivityMonitor: activity, bluetoothScanner: RecordingBluetoothScanner())
        defer { model.shutdown() }
        let center = NotificationCenter()
        model.workspaceNotificationCenterOverride = center
        model.displayUnavailableProbe = { false }
        model.screenLockStateProbe = { .locked }
        model.settings.isEnabled = true
        model.settings.lockRSSI = BLEUnlockModel.lockDisabled
        model.settings.unlockRSSI = -70
        model.startObservingSystemState()
        model.startMonitor(UUID())
        now = 131
        model.evaluateUserActivityPolicy()
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        now = 131 + BLEUserActivityMonitor.unlockRecoveryWakeGrace - 1
        model.evaluateUserActivityPolicy()
        #expect(!model.activeConnectionsPaused)
        now += 1
        model.evaluateUserActivityPolicy()
        #expect(model.activeConnectionsPaused)
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        #expect(model.activeConnectionsPaused, "A repeated notification must not keep Bluetooth active indefinitely")
    }

    @Test func displayWakePreemptsAnOlderSignalTimeoutRecovery() {
        let scanner = RecordingBluetoothScanner()
        let model = BLEUnlockModel(
            userActivityMonitor: BLEUserActivityMonitor(observesEvents: false),
            bluetoothScanner: scanner
        )
        defer { model.shutdown() }
        let workspaceCenter = NotificationCenter()
        model.workspaceNotificationCenterOverride = workspaceCenter
        model.displayUnavailableProbe = { false }
        model.settings.isEnabled = true
        // This timeout exercises recovery, never the user's real lock screen.
        model.settings.lockRSSI = BLEUnlockModel.lockDisabled
        model.settings.unlockRSSI = BLEUnlockModel.unlockDisabled
        model.startObservingSystemState()
        let monitored = UUID()
        model.startMonitor(monitored)
        model.handleMonitoredSignalTimeout(for: monitored)
        let resetsBeforeWake = scanner.centralResets
        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)

        workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)

        #expect(scanner.scanRestarts == 1, "An earlier recovery must not defer the wake scan")
        #expect(scanner.centralResets == resetsBeforeWake)
    }

    @Test func manualDisplayUnblankImmediatelyRestartsDiscovery() {
        let scanner = RecordingBluetoothScanner()
        let model = BLEUnlockModel(
            userActivityMonitor: BLEUserActivityMonitor(observesEvents: false),
            bluetoothScanner: scanner
        )
        defer { model.shutdown() }
        var isBlanked = false
        let blankCenter = NotificationCenter()
        model.displayUnavailableProbe = { isBlanked }
        model.heldBlankNotificationCenterOverride = blankCenter
        model.settings.isEnabled = true
        model.startObservingSystemState()
        model.startMonitor(UUID())
        isBlanked = true
        blankCenter.post(name: DisplayPower.blankStateDidChangeNotification, object: nil)
        #expect(scanner.scanRestarts == 0)

        isBlanked = false
        blankCenter.post(name: DisplayPower.blankStateDidChangeNotification, object: nil)

        #expect(scanner.scanRestarts == 1)
        #expect(scanner.centralResets == 0)
        #expect(!model.activeConnectionsPaused)
    }

    @Test func displayWakeImmediatelyRestartsScanningWithoutReplacingTheCentral() {
        let scanner = RecordingBluetoothScanner()
        let model = BLEUnlockModel(
            userActivityMonitor: BLEUserActivityMonitor(observesEvents: false),
            bluetoothScanner: scanner
        )
        defer { model.shutdown() }
        let workspaceCenter = NotificationCenter()
        model.workspaceNotificationCenterOverride = workspaceCenter
        model.displayUnavailableProbe = { false }
        model.screenLockStateProbe = { .locked }
        model.settings.isEnabled = true
        model.settings.unlockRSSI = -70
        model.settings.lockRSSI = BLEUnlockModel.lockDisabled
        model.startObservingSystemState()
        let monitored = UUID()
        model.startMonitor(monitored)
        model.updateMonitoredPeripheral(-50, for: monitored)
        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)

        workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)

        #expect(scanner.scanRestarts == 1, "Discovery must restart synchronously on display wake")
        #expect(scanner.centralResets == 0, "The reconnect must keep its CoreBluetooth session")
        #expect(!model.presence, "Pre-wake RSSI must not authorize unlock")
        #expect(!model.isUnlockAttemptScheduled)

        model.updateMonitoredPeripheral(-50, for: monitored)
        #expect(model.presence)
        #expect(model.isUnlockAttemptScheduled, "Fresh nearby signal must resume automatic unlock")
    }

    @Test func displayWakeScanRetriesPreserveTheCentralAndStopAfterFreshSignal() async {
        let scanner = RecordingBluetoothScanner()
        let model = BLEUnlockModel(
            userActivityMonitor: BLEUserActivityMonitor(observesEvents: false),
            bluetoothScanner: scanner
        )
        defer { model.shutdown() }
        let delays = AsyncStream<TimeInterval>.makeStream()
        var sleepContinuation: CheckedContinuation<Void, Never>?
        model.monitoringRecoverySleep = { delay in
            await withCheckedContinuation { continuation in
                sleepContinuation = continuation
                delays.continuation.yield(delay)
            }
        }
        defer {
            sleepContinuation?.resume()
            delays.continuation.finish()
        }
        let workspaceCenter = NotificationCenter()
        model.workspaceNotificationCenterOverride = workspaceCenter
        model.displayUnavailableProbe = { false }
        model.settings.isEnabled = true
        model.settings.unlockRSSI = BLEUnlockModel.unlockDisabled
        model.settings.lockRSSI = BLEUnlockModel.lockDisabled
        model.startObservingSystemState()
        let monitored = UUID()
        model.startMonitor(monitored)
        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)

        var delayIterator = delays.stream.makeAsyncIterator()
        let firstDelay = await delayIterator.next()
        #expect(firstDelay == 3)
        sleepContinuation?.resume()
        sleepContinuation = nil
        let secondDelay = await delayIterator.next()
        #expect(secondDelay == 7)
        #expect(scanner.scanRestarts == 2)
        #expect(scanner.centralResets == 0, "The three-second retry must not cancel a pending connection")
        let taskCount = model.diagnosticTaskCount
        model.updateMonitoredPeripheral(-50, for: monitored)
        #expect(model.presence)
        // Fresh RSSI cancels the remaining ten-second scan retry immediately.
        #expect(model.diagnosticTaskCount == taskCount - 1)
    }

    @Test func absentSecondaryDoesNotResetAFreshPrimaryInAnyDeviceMode() {
        let primary = UUID()
        let secondary = UUID()
        let model = BLEUnlockModel(userActivityMonitor: BLEUserActivityMonitor(observesEvents: false))
        defer { model.shutdown() }
        model.settings.isEnabled = true
        model.settings.deviceRelation = .any
        model.settings.unlockRSSI = BLEUnlockModel.unlockDisabled
        model.settings.lockRSSI = BLEUnlockModel.lockDisabled
        model.secondaryMonitoredUUID = secondary
        model.startMonitor(primary)
        model.updateMonitoredPeripheral(-50, for: primary)
        let taskCount = model.diagnosticTaskCount

        model.handleMonitoredSignalTimeout(for: secondary)

        #expect(model.presence)
        #expect(model.lastRSSI == -50)
        #expect(model.diagnosticTaskCount == taskCount)
    }

    @Test func activeRecoveryReconnectsKnownDevicesWithoutAnAdvertisement() {
        let known = UUID()
        let unknown = UUID()
        var retrieved: [UUID] = []
        var connected: [UUID] = []
        var timeouts: [UUID] = []
        BLEMonitoringRestoration.restore(
            identifiers: [known, unknown],
            passiveMode: false,
            retrieve: { identifier -> String? in
                retrieved.append(identifier)
                return identifier == known ? "cached peripheral" : nil
            },
            connect: { identifier, device in
                #expect(device == "cached peripheral")
                connected.append(identifier)
            },
            armSignalTimeout: { timeouts.append($0) }
        )
        #expect(retrieved == [known, unknown])
        #expect(connected == [known])
        // Unknown or absent devices must still get another recovery opportunity.
        #expect(timeouts == [known, unknown])
    }

    @Test func passiveRecoveryArmsTimeoutsWithoutConnecting() {
        let identifier = UUID()
        var timeouts: [UUID] = []
        BLEMonitoringRestoration.restore(
            identifiers: [identifier],
            passiveMode: true,
            retrieve: { _ -> String? in
                Issue.record("Passive monitoring must not retrieve devices for connection")
                return "device"
            },
            connect: { _, _ in Issue.record("Passive monitoring must not connect") },
            armSignalTimeout: { timeouts.append($0) }
        )
        #expect(timeouts == [identifier])
    }

    @Test func displaySleepRecoveryKeepsPassiveScanningWithoutRetrievingForConnection() {
        let identifier = UUID()
        var timeouts: [UUID] = []
        BLEMonitoringRestoration.restore(
            identifiers: [identifier],
            passiveMode: false,
            activeConnectionsPaused: true,
            retrieve: { _ -> String? in
                Issue.record("A sleeping display must not retrieve a peripheral for connection")
                return "cached peripheral"
            },
            connect: { _, _ in Issue.record("A sleeping display must not reconnect") },
            armSignalTimeout: { timeouts.append($0) }
        )
        #expect(timeouts == [identifier])
    }

    @Test func explicitProximityWakeKeepsActiveConnectionPolicyEnabledDuringDisplaySleep() {
        #expect(!BLEActiveConnectionPolicy.shouldPause(
            displayAsleep: true,
            systemAsleep: false,
            wakeOnProximity: true
        ))
        #expect(!BLEActiveConnectionPolicy.shouldPauseForUserInactivity(
            wakeOnProximity: true,
            userIsActive: false
        ))
    }

    @Test func startupAndRecentInputPreventIdlePauseUntilThirtySecondsPass() {
        var now: TimeInterval = 100
        let monitor = BLEUserActivityMonitor(uptime: { now }, observesEvents: false)
        monitor.start()
        #expect(monitor.isUserActive(at: 129.9))
        #expect(!monitor.isUserActive(at: 130))

        monitor.recordInput(at: 140)
        #expect(monitor.isUserActive(at: 169.9))
        #expect(!monitor.isUserActive(at: 170))
        now = 171
        #expect(!monitor.isUserActive(at: now))
        monitor.stop()
        now = 200
        monitor.start()
        #expect(monitor.isUserActive(at: 229.9), "Re-enabling BLE starts a fresh grace window")
    }

    @Test func idleModelCancelsUnlockAndObservedInputResumesIt() {
        var now: TimeInterval = 100
        let activity = BLEUserActivityMonitor(uptime: { now }, observesEvents: false)
        let model = BLEUnlockModel(userActivityMonitor: activity, bluetoothScanner: RecordingBluetoothScanner())
        defer { model.shutdown() }
        let workspaceCenter = NotificationCenter()
        model.workspaceNotificationCenterOverride = workspaceCenter
        model.displayUnavailableProbe = { false }
        model.screenLockStateProbe = { .locked }
        model.settings.isEnabled = true
        model.settings.unlockRSSI = -70
        model.settings.lockRSSI = BLEUnlockModel.lockDisabled
        model.startObservingSystemState()
        #expect(activity.isMonitoring)
        let monitored = UUID()
        model.startMonitor(monitored)
        model.updateMonitoredPeripheral(-50, for: monitored)
        model.updatePresence(presence: true, reason: "test-before-idle")
        #expect(model.isUnlockAttemptScheduled)

        now = 131
        model.evaluateUserActivityPolicy()
        #expect(model.activeConnectionsPaused)
        #expect(!model.isUnlockAttemptScheduled)

        model.handleMonitoredSignalTimeout(for: monitored)
        model.updateMonitoredPeripheral(-50, for: monitored)
        #expect(model.presence)
        #expect(!model.isUnlockAttemptScheduled, "A new presence edge during idle must not schedule unlock")

        model.recordUserInput(at: now)
        #expect(!model.activeConnectionsPaused)
        #expect(model.isUnlockAttemptScheduled)

        let taskCountBeforeObserverStop = model.diagnosticTaskCount
        model.stopObservingSystemState()
        #expect(!activity.isMonitoring)
        #expect(model.diagnosticTaskCount < taskCountBeforeObserverStop)
    }

    @Test func repeatedDisplayWakeNotificationsCannotRenewIdleAllowance() {
        var now: TimeInterval = 100
        let activity = BLEUserActivityMonitor(uptime: { now }, observesEvents: false)
        let model = BLEUnlockModel(userActivityMonitor: activity)
        defer { model.shutdown() }
        let workspaceCenter = NotificationCenter()
        model.workspaceNotificationCenterOverride = workspaceCenter
        model.displayUnavailableProbe = { false }
        model.screenLockStateProbe = { .unlocked }
        model.settings.isEnabled = true
        model.startObservingSystemState()

        now = 131
        model.evaluateUserActivityPolicy()
        #expect(model.activeConnectionsPaused)
        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        #expect(!model.activeConnectionsPaused, "A real sleep/wake transition gets one short allowance")

        now = 141
        model.evaluateUserActivityPolicy()
        #expect(model.activeConnectionsPaused)
        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        #expect(model.activeConnectionsPaused, "A second wake in this idle epoch cannot renew the allowance")

        model.recordUserInput(at: now)
        #expect(!model.activeConnectionsPaused, "Real input restores the active connection policy")
    }

    @Test func displayWakeAllowanceIsFiniteAndCannotRenewUntilActualInput() {
        var now: TimeInterval = 100
        let monitor = BLEUserActivityMonitor(uptime: { now }, observesEvents: false)
        monitor.start()
        now = 131
        #expect(!monitor.isUserActive(at: now))

        monitor.noteDisplayWake(fromSleep: true)
        #expect(monitor.isUserActive(at: now))
        now = 141
        #expect(!monitor.isUserActive(at: now))
        monitor.noteDisplayWake(fromSleep: true)
        #expect(!monitor.isUserActive(at: now), "Repeated wake notifications must not extend the allowance")

        monitor.recordInput(at: now)
        now = 172
        #expect(!monitor.isUserActive(at: now))
        monitor.noteDisplayWake(fromSleep: true)
        #expect(monitor.isUserActive(at: now), "Actual input begins a new idle epoch")
    }

    @Test func noOpPointerAndMarkedUnlockEventsDoNotCountAsUserInput() throws {
        let source = CGEventSource(stateID: .hidSystemState)
        let noOp = try #require(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: .zero, mouseButton: .left))
        #expect(!BLEUserActivityMonitor.isGenuineUserInput(try #require(NSEvent(cgEvent: noOp))))

        let movement = try #require(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: .zero, mouseButton: .left))
        movement.setDoubleValueField(.mouseEventDeltaX, value: 1)
        #expect(BLEUserActivityMonitor.isGenuineUserInput(try #require(NSEvent(cgEvent: movement))))

        let synthetic = try #require(CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true))
        BLEUserActivityMonitor.markAutomaticUnlockEvent(synthetic)
        #expect(!BLEUserActivityMonitor.isGenuineUserInput(try #require(NSEvent(cgEvent: synthetic))))
    }

    @Test func heldBlankNotificationPausesConnectionsCancelsUnlockAndResumesOnUnblank() {
        let model = BLEUnlockModel(
            userActivityMonitor: BLEUserActivityMonitor(observesEvents: false),
            bluetoothScanner: RecordingBluetoothScanner()
        )
        defer { model.shutdown() }
        var isBlanked = false
        let blankCenter = NotificationCenter()
        model.displayUnavailableProbe = { isBlanked }
        model.screenLockStateProbe = { .locked }
        model.heldBlankNotificationCenterOverride = blankCenter
        model.settings.isEnabled = true
        model.settings.unlockRSSI = -70
        model.startObservingSystemState()
        let phone = UUID()
        model.startMonitor(phone)
        model.updateMonitoredPeripheral(-50, for: phone)

        model.updatePresence(presence: true, reason: "test-before-blank")
        #expect(model.isUnlockAttemptScheduled)
        #expect(!model.activeConnectionsPaused)

        isBlanked = true
        blankCenter.post(name: DisplayPower.blankStateDidChangeNotification, object: nil)
        #expect(model.activeConnectionsPaused)
        #expect(!model.isUnlockAttemptScheduled)

        isBlanked = false
        blankCenter.post(name: DisplayPower.blankStateDidChangeNotification, object: nil)
        #expect(!model.activeConnectionsPaused)
    }

    @Test func asleepDisplayWithoutWakeDoesNotScheduleUnlockButExplicitWakeCan() {
        let model = BLEUnlockModel(
            userActivityMonitor: BLEUserActivityMonitor(observesEvents: false),
            bluetoothScanner: RecordingBluetoothScanner()
        )
        defer { model.shutdown() }
        var displayUnavailable = true
        model.displayUnavailableProbe = { displayUnavailable }
        model.screenLockStateProbe = { .locked }
        model.settings.isEnabled = true
        model.settings.unlockRSSI = -70
        let phone = UUID()
        model.startMonitor(phone)
        model.updateMonitoredPeripheral(-50, for: phone)
        model.updatePresence(presence: true, reason: "test-asleep")
        #expect(model.activeConnectionsPaused)
        #expect(!model.isUnlockAttemptScheduled)

        model.setWakeOnProximity(true)
        #expect(!model.activeConnectionsPaused)
        model.updatePresence(presence: true, reason: "test-explicit-wake")
        #expect(model.isUnlockAttemptScheduled)
        displayUnavailable = false
    }

    @Test func systemDisplaySleepAndWakeNotificationsToggleTheModelConnectionPolicy() {
        let model = BLEUnlockModel(userActivityMonitor: BLEUserActivityMonitor(observesEvents: false))
        defer { model.shutdown() }
        let workspaceCenter = NotificationCenter()
        model.workspaceNotificationCenterOverride = workspaceCenter
        model.displayUnavailableProbe = { false }
        model.settings.isEnabled = true
        model.startObservingSystemState()

        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        #expect(model.activeConnectionsPaused)

        workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        #expect(!model.activeConnectionsPaused)
    }
}

@MainActor
private final class RecordingBluetoothScanner: BluetoothScanning {
    var central: CBCentralManager? {
        get { nil }
        set { centralResets += 1 }
    }
    private(set) var scanRestarts = 0
    private(set) var centralResets = 0
    func createIfNeeded(delegate: CBCentralManagerDelegate) {}
    func startIfPoweredOn() -> Bool { true }
    func restartIfPoweredOn() -> Bool {
        scanRestarts += 1
        return true
    }
    func stop() {}
    func release() {}
}
