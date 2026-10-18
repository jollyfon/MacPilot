import CoreBluetooth
import Foundation
import Testing
@testable import MacPilot

@MainActor
struct BLEDevicePickerScanTests {
    @Test func onlyTheDevicePickerRequestsDuplicateAdvertisements() {
        #expect(BLEScanPolicy.scanOptions(allowsDuplicateAdvertisements: false) == nil)
        let options = BLEScanPolicy.scanOptions(allowsDuplicateAdvertisements: true)
        #expect(options?[CBCentralManagerScanOptionAllowDuplicatesKey] as? Bool == true)
    }

    @Test func openingThePickerStartsAContinuousAdvertisementStream() {
        let h = Harness()
        defer { h.model.shutdown() }

        h.model.startScanning()

        #expect(h.model.isScanning)
        #expect(h.scanner.duplicateModes == [true])
        #expect(h.scanner.restarts == 1, "An already-running monitoring scan must be restarted with the new options")
    }

    @Test func closingThePickerRestoresTheBoundedMonitoringScan() {
        let h = Harness()
        defer { h.model.shutdown() }
        h.model.settings.isEnabled = true
        h.model.startMonitor(h.phone)
        let startsBeforePicker = h.scanner.starts

        h.model.startScanning()
        h.model.stopScanning()

        #expect(!h.model.isScanning)
        #expect(h.scanner.duplicateModes == [true, false])
        #expect(h.scanner.restarts == 2)
        #expect(h.scanner.starts == startsBeforePicker, "Monitoring must keep its scan running after the picker closes")
        #expect(h.scanner.stops == 0)
    }

    @Test func closingThePickerStopsTheRadioWhenNothingIsMonitored() {
        let h = Harness()
        defer { h.model.shutdown() }
        h.model.settings.isEnabled = false

        h.model.startScanning()
        h.model.stopScanning()

        #expect(h.scanner.duplicateModes == [true, false])
        #expect(h.scanner.stops == 1)
    }

    @MainActor
    private final class Harness {
        let phone = UUID()
        let scanner = Scanner()
        var model: BLEUnlockModel!

        init() {
            model = BLEUnlockModel(
                userActivityMonitor: BLEUserActivityMonitor(uptime: { 1_000 }, observesEvents: false),
                bluetoothScanner: scanner,
                eventScriptRunner: { _ in }
            )
            model.displayUnavailableProbe = { false }
            model.screenLockStateProbe = { .unlocked }
            model.lockScreenOperation = { _ in }
            model.settings.unlockRSSI = BLEUnlockModel.unlockDisabled
            model.settings.pauseNowPlaying = false
            model.signalTimeoutScheduler = { _, _ in BackgroundTask.once(after: 3_600) {} }
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
        var stops = 0
        var duplicateModes: [Bool] = []

        func createIfNeeded(delegate: CBCentralManagerDelegate) {}
        func startIfPoweredOn() -> Bool { starts += 1; return true }
        func restartIfPoweredOn() -> Bool { restarts += 1; return true }
        func stop() { stops += 1 }
        func release() {}
        func setAllowsDuplicateAdvertisements(_ allowed: Bool) { duplicateModes.append(allowed) }
    }
}
