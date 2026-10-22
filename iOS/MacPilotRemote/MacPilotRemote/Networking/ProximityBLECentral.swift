import CoreBluetooth
import Foundation
import MacPilotRemoteTransport

/// Scans for the Mac's reversed-role GATT service and measures every step.
///
/// This is the phone half of the phase-one feasibility harness. It never starts
/// on its own: the user opens the test screen and taps start, so the Bluetooth
/// permission prompt and the radio session stay tied to an explicit action.
/// Nothing here authenticates the Mac or feeds the unlock path.
@MainActor
final class ProximityBLECentral: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    enum Status: Equatable {
        case idle
        case starting
        case scanning
        case connecting
        case discovering
        case echoing
        case verified(roundTripMs: Int)
        case failed(String)
    }

    struct Timings: Equatable {
        var connectMs: Int?
        var discoverMs: Int?
        var readMs: Int?
        var subscribeMs: Int?
        var echoMs: Int?
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var logLines: [String] = []
    @Published private(set) var macInfo: ProximityGATTMacInfo?
    @Published private(set) var timings = Timings()
    @Published private(set) var isRunning = false

    private var manager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var echoCharacteristic: CBCharacteristic?
    private var responseCharacteristic: CBCharacteristic?
    private var sentEcho: Data?
    private var sentAt: Date?
    private var attemptStartedAt: Date?
    private var connectStartedAt: Date?
    private var discoverStartedAt: Date?
    private var readStartedAt: Date?
    private var subscribeStartedAt: Date?
    private var timeoutTask: Task<Void, Never>?
    private let attemptTimeout: TimeInterval = 15
    private let logLimit = 200

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        resetAttempt()
        status = .starting
        log("central starting")
        if manager == nil {
            manager = CBCentralManager(
                delegate: self,
                queue: .main,
                options: [CBCentralManagerOptionShowPowerAlertKey: false]
            )
        } else {
            beginScanning()
        }
    }

    func stop() {
        isRunning = false
        timeoutTask?.cancel()
        timeoutTask = nil
        manager?.stopScan()
        if let peripheral {
            manager?.cancelPeripheralConnection(peripheral)
            peripheral.delegate = nil
        }
        peripheral = nil
        echoCharacteristic = nil
        responseCharacteristic = nil
        sentEcho = nil
        manager?.delegate = nil
        manager = nil
        status = .idle
        log("central stopped")
    }

    private func resetAttempt() {
        timeoutTask?.cancel()
        timeoutTask = nil
        manager?.stopScan()
        if let peripheral {
            manager?.cancelPeripheralConnection(peripheral)
            peripheral.delegate = nil
        }
        peripheral = nil
        echoCharacteristic = nil
        responseCharacteristic = nil
        sentEcho = nil
        sentAt = nil
        macInfo = nil
        timings = Timings()
        attemptStartedAt = nil
        connectStartedAt = nil
        discoverStartedAt = nil
        readStartedAt = nil
        subscribeStartedAt = nil
    }

    private func beginScanning() {
        guard isRunning, peripheral == nil, let manager, manager.state == .poweredOn else { return }
        guard !manager.isScanning else { return }
        status = .scanning
        log("scanning for \(ProximityGATTService.serviceUUID.uuidString)")
        manager.scanForPeripherals(withServices: [ProximityGATTService.serviceUUID], options: nil)
    }

    private func scheduleTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.attemptTimeout ?? 15))
            guard let self, !Task.isCancelled, self.isRunning else { return }
            if case .verified = self.status { return }
            self.fail("timed out while \(self.statusLabel)")
        }
    }

    private var statusLabel: String {
        switch status {
        case .idle: return "idle"
        case .starting: return "starting"
        case .scanning: return "scanning"
        case .connecting: return "connecting"
        case .discovering: return "discovering"
        case .echoing: return "waiting for the echo"
        case .verified: return "verified"
        case .failed: return "failed"
        }
    }

    private func fail(_ reason: String) {
        guard isRunning else { return }
        isRunning = false
        timeoutTask?.cancel()
        timeoutTask = nil
        manager?.stopScan()
        if let peripheral {
            manager?.cancelPeripheralConnection(peripheral)
            peripheral.delegate = nil
        }
        peripheral = nil
        echoCharacteristic = nil
        responseCharacteristic = nil
        status = .failed(reason)
        log("failed: \(reason)")
    }

    private func log(_ message: @autoclosure () -> String) {
        let line = "\(Date.now.formatted(date: .omitted, time: .standard)) \(message())"
        logLines.append(line)
        if logLines.count > logLimit {
            logLines.removeFirst(logLines.count - logLimit)
        }
    }

    private func elapsedMs(since start: Date?) -> Int? {
        guard let start else { return nil }
        return max(0, Int((Date.now.timeIntervalSince(start) * 1000).rounded()))
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === manager else { return }
        switch central.state {
        case .poweredOn:
            log("radio on")
            if isRunning { beginScanning() }
        case .unauthorized:
            fail("Bluetooth unauthorized")
        case .unsupported:
            fail("Bluetooth unsupported")
        case .poweredOff:
            fail("Bluetooth is off")
        default:
            log("waiting for Bluetooth state=\(central.state.rawValue)")
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard central === manager, isRunning, self.peripheral == nil else { return }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        connectStartedAt = .now
        status = .connecting
        log("discovered name=\(peripheral.name ?? "unknown") uuid=\(peripheral.identifier.uuidString) rssi=\(RSSI.intValue)")
        scheduleTimeout()
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === manager, peripheral === self.peripheral else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        timings.connectMs = elapsedMs(since: connectStartedAt)
        log("connected in \(timings.connectMs ?? 0) ms")
        discoverStartedAt = .now
        status = .discovering
        peripheral.discoverServices([ProximityGATTService.serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard central === manager, peripheral === self.peripheral else { return }
        fail("connection failed: \(error?.localizedDescription ?? "unknown error")")
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard central === manager, peripheral === self.peripheral else { return }
        if case .verified = status {
            self.peripheral = nil
            echoCharacteristic = nil
            responseCharacteristic = nil
            isRunning = false
            log("disconnected after a verified echo")
        } else {
            fail("disconnected: \(error?.localizedDescription ?? "no error")")
        }
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.peripheral else { return }
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == ProximityGATTService.serviceUUID }) else {
            fail("service lookup failed: \(error?.localizedDescription ?? "not found")")
            return
        }
        log("service found; discovering characteristics")
        peripheral.discoverCharacteristics([
            ProximityGATTService.macInfoCharacteristicUUID,
            ProximityGATTService.echoCharacteristicUUID,
            ProximityGATTService.responseCharacteristicUUID
        ], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === self.peripheral else { return }
        guard error == nil else {
            fail("characteristic lookup failed: \(error?.localizedDescription ?? "unknown error")")
            return
        }
        let characteristics = service.characteristics ?? []
        guard let macInfo = characteristics.first(where: { $0.uuid == ProximityGATTService.macInfoCharacteristicUUID }),
              let echo = characteristics.first(where: { $0.uuid == ProximityGATTService.echoCharacteristicUUID }),
              let response = characteristics.first(where: { $0.uuid == ProximityGATTService.responseCharacteristicUUID }) else {
            fail("one or more characteristics are missing")
            return
        }
        echoCharacteristic = echo
        responseCharacteristic = response
        timings.discoverMs = elapsedMs(since: discoverStartedAt)
        log("characteristics found in \(timings.discoverMs ?? 0) ms; reading Mac info")
        readStartedAt = .now
        peripheral.readValue(for: macInfo)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral else { return }
        if characteristic.uuid == ProximityGATTService.macInfoCharacteristicUUID {
            handleMacInfo(characteristic, error: error)
        } else if characteristic.uuid == ProximityGATTService.echoCharacteristicUUID {
            handleEcho(characteristic, error: error)
        }
    }

    private func handleMacInfo(_ characteristic: CBCharacteristic, error: Error?) {
        if let error {
            fail("Mac info read failed: \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value, let info = ProximityGATTMacInfo(encoded: data) else {
            fail("Mac info decode failed (\(characteristic.value?.count ?? 0) bytes)")
            return
        }
        macInfo = info
        timings.readMs = elapsedMs(since: readStartedAt)
        log("Mac info version=\(ProximityGATTMacInfo.version) id=\(info.deviceID?.uuidString ?? "not configured") read in \(timings.readMs ?? 0) ms")
        guard let echoCharacteristic else {
            fail("echo characteristic disappeared")
            return
        }
        subscribeStartedAt = .now
        peripheral?.setNotifyValue(true, for: echoCharacteristic)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard peripheral === self.peripheral,
              characteristic.uuid == ProximityGATTService.echoCharacteristicUUID else { return }
        if let error {
            fail("subscribe failed: \(error.localizedDescription)")
            return
        }
        guard characteristic.isNotifying else {
            fail("Mac refused the echo subscription")
            return
        }
        timings.subscribeMs = elapsedMs(since: subscribeStartedAt)
        log("subscribed in \(timings.subscribeMs ?? 0) ms; writing echo")
        sendEcho()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard peripheral === self.peripheral,
              characteristic.uuid == ProximityGATTService.responseCharacteristicUUID else { return }
        if let error {
            fail("echo write failed: \(error.localizedDescription)")
            return
        }
        log("echo write acknowledged; waiting for the notification")
    }

    private func sendEcho() {
        guard let peripheral, let responseCharacteristic else { return }
        let payload = ProximityGATTEcho.random()
        sentEcho = payload
        sentAt = .now
        status = .echoing
        peripheral.writeValue(payload, for: responseCharacteristic, type: .withResponse)
    }

    private func handleEcho(_ characteristic: CBCharacteristic, error: Error?) {
        if let error {
            fail("echo notification failed: \(error.localizedDescription)")
            return
        }
        guard let sentEcho, let received = characteristic.value else {
            fail("echo arrived without a pending payload")
            return
        }
        guard ProximityGATTEcho.isValid(received, matching: sentEcho) else {
            fail("echo mismatch: sent \(sentEcho.count) bytes, received \(received.count)")
            return
        }
        let roundTrip = elapsedMs(since: sentAt) ?? 0
        timings.echoMs = roundTrip
        timeoutTask?.cancel()
        timeoutTask = nil
        status = .verified(roundTripMs: roundTrip)
        log("echo verified in \(roundTrip) ms")
    }
}
