import CoreBluetooth
import Foundation
import Testing
@testable import MacPilot

@MainActor
struct BLEBackgroundSessionTests {
    @Test func aBackgroundSessionDoesNotStartMonitoringOrScanningAtLaunch() {
        let h = Harness(onConsole: false)
        defer { h.model.shutdown() }
        h.model.settings.isEnabled = true

        h.model.activateFromConfiguration()
        h.model.startMonitor(h.phone)
        h.model.handleCentralStateChange(.poweredOn)

        #expect(h.model.diagnosticObserverCount > 0, "Observers must stay installed so the return can resume BLE")
        #expect(h.model.runtime(for: h.phone) == nil)
        #expect(h.scanner.starts == 0)
    }

    @Test func returningToTheConsoleResumesMonitoringAfterABackgroundLaunch() {
        let h = Harness(onConsole: false)
        defer { h.model.shutdown() }
        h.model.settings.isEnabled = true
        h.model.activateFromConfiguration()
        h.model.startMonitor(h.phone)
        #expect(h.model.runtime(for: h.phone) == nil)

        h.onConsoleFlag = true
        h.model.handleSessionDidBecomeActive()
        h.model.handleCentralStateChange(.poweredOn)

        #expect(h.model.runtime(for: h.phone) != nil)
        #expect(h.model.diagnosticTaskCount > 0)
    }

    @Test func leavingTheConsoleReleasesTheCentralAndItsConnections() {
        let h = Harness(onConsole: true)
        defer { h.model.shutdown() }
        h.model.settings.isEnabled = true
        h.model.activateFromConfiguration()
        h.model.startMonitor(h.phone)
        #expect(h.model.runtime(for: h.phone) != nil)

        h.onConsoleFlag = false
        h.model.handleSessionDidResignActive()

        #expect(h.model.runtime(for: h.phone) == nil)
        #expect(h.scanner.releases == 1)
        #expect(!h.model.presence)
        #expect(h.model.diagnosticTaskCount == 0)

        h.onConsoleFlag = true
        h.model.handleSessionDidBecomeActive()
        h.model.handleCentralStateChange(.poweredOn)
        #expect(h.model.runtime(for: h.phone) != nil)
        #expect(h.scanner.releases == 1, "Returning to the console must recreate, not release, the central")
    }

    @Test func aBackgroundSessionCannotLockTheActiveUsersScreen() {
        let h = Harness(onConsole: false)
        defer { h.model.shutdown() }
        h.model.settings.isEnabled = true
        h.model.activateFromConfiguration()

        h.model.lockNow()

        #expect(h.locks.isEmpty)
    }

    @Test func theDevicePickerResumesAfterReturningToTheConsole() {
        let h = Harness(onConsole: true)
        defer { h.model.shutdown() }
        h.model.settings.isEnabled = true
        h.model.activateFromConfiguration()
        h.model.startScanning()
        #expect(h.model.isScanning)

        h.onConsoleFlag = false
        h.model.handleSessionDidResignActive()
        #expect(!h.model.isScanning)

        h.onConsoleFlag = true
        h.model.handleSessionDidBecomeActive()

        #expect(h.model.isScanning)
        #expect(h.scanner.duplicateModes == [true, false, true])
    }

    @MainActor
    private final class Harness {
        let phone = UUID()
        let scanner = Scanner()
        var onConsoleFlag: Bool
        var model: BLEUnlockModel!
        var locks: [ScreenControlSource] = []

        init(onConsole: Bool) {
            onConsoleFlag = onConsole
            let scanner = self.scanner
            model = BLEUnlockModel(
                userActivityMonitor: BLEUserActivityMonitor(uptime: { 1_000 }, observesEvents: false),
                bluetoothScanner: scanner,
                eventScriptRunner: { _ in }
            )
            model.sessionOnConsoleProbe = { [weak self] in self?.onConsoleFlag ?? true }
            model.workspaceNotificationCenterOverride = NotificationCenter()
            model.heldBlankNotificationCenterOverride = NotificationCenter()
            model.screenStateNotificationCenterOverride = NotificationCenter()
            model.displayUnavailableProbe = { false }
            model.screenLockStateProbe = { .unlocked }
            model.lockScreenOperation = { [weak self] in self?.locks.append($0) }
            model.settings.unlockRSSI = BLEUnlockModel.unlockDisabled
            model.settings.pauseNowPlaying = false
            model.signalTimeoutScheduler = { _, _ in BackgroundTask.once(after: 3_600) {} }
            model.proximityTimeoutScheduler = { _, _ in BackgroundTask.once(after: 3_600) {} }
        }
    }

    @MainActor
    private final class Scanner: BluetoothScanning {
        var central: CBCentralManager? {
            get { nil }
            set {}
        }
        var starts = 0
        var restarts = 0
        var releases = 0
        var duplicateModes: [Bool] = []

        func createIfNeeded(delegate: CBCentralManagerDelegate) {}
        func startIfPoweredOn() -> Bool { starts += 1; return true }
        func restartIfPoweredOn() -> Bool { restarts += 1; return true }
        func stop() {}
        func release() { releases += 1 }
        func setAllowsDuplicateAdvertisements(_ allowed: Bool) { duplicateModes.append(allowed) }
    }
}
