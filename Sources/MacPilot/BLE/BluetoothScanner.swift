import CoreBluetooth
import Foundation

/// The monitored peripherals receive their periodic RSSI reads through the
/// connected-peripheral path below; duplicate advertisements only create an
/// unbounded XPC/Mach-message stream on macOS.
enum BLEScanPolicy {
    static let allowsDuplicateAdvertisements = false

    /// A deduplicated scan is discovery, not a continuous presence stream.
    /// Refresh it at a bounded rate when a logical device has no recent RSSI.
    static func rediscoveryInterval(signalTimeout: Int) -> TimeInterval {
        min(10, max(1, TimeInterval(signalTimeout) / 3))
    }

    static func needsAdvertisements(connectionState: CBPeripheralState?, hasRSSIPoller: Bool) -> Bool {
        connectionState != .connected || !hasRSSIPoller
    }

    static var scanOptions: [String: Any]? {
        allowsDuplicateAdvertisements
            ? [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            : nil
    }
}


/// Owns the CoreBluetooth session so feature stop can close its XPC/delegate
/// graph, not merely stop advertising callbacks.
@MainActor
protocol BluetoothScanning: AnyObject {
    var central: CBCentralManager? { get set }
    func createIfNeeded(delegate: CBCentralManagerDelegate)
    func startIfPoweredOn() -> Bool
    func restartIfPoweredOn() -> Bool
    func stop()
    func release()
}

@MainActor
final class BluetoothScanner: BluetoothScanning {
    var central: CBCentralManager?

    func createIfNeeded(delegate: CBCentralManagerDelegate) {
        guard central == nil else { return }
        central = CBCentralManager(
            delegate: delegate,
            queue: nil,
            options: [CBCentralManagerOptionShowPowerAlertKey: false]
        )
    }

    func startIfPoweredOn() -> Bool {
        guard let central, central.state == .poweredOn else { return false }
        guard !central.isScanning else { return true }
        central.scanForPeripherals(withServices: nil, options: BLEScanPolicy.scanOptions)
        return true
    }

    func stop() { central?.stopScan() }

    /// Start a new discovery session without cancelling pending connections.
    func restartIfPoweredOn() -> Bool {
        guard let central, central.state == .poweredOn else { return false }
        central.stopScan()
        // Do not trust an isScanning value left over from display sleep.
        central.scanForPeripherals(withServices: nil, options: BLEScanPolicy.scanOptions)
        return true
    }

    func release() {
        central?.stopScan()
        central?.delegate = nil
        central = nil
    }
}
