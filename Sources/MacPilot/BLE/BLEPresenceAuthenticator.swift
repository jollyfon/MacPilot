import CoreBluetooth
import Foundation
import MacPilotRemoteProtocol
import MacPilotRemoteTransport

enum BLEPresenceAuthenticationPolicy {
    /// How long one observed address is left alone after a failed challenge.
    /// Rotation produces a new address anyway; this only keeps a phone without
    /// the characteristic (or a stranger's PilotNest) from being reconnected
    /// every few seconds.
    static let retryInterval: TimeInterval = 60

    static func shouldAttempt(
        isMonitored: Bool,
        hasBindings: Bool,
        hasMacIdentity: Bool,
        lastAttemptAt: Date?,
        now: Date,
        retryInterval: TimeInterval = retryInterval
    ) -> Bool {
        guard !isMonitored, hasBindings, hasMacIdentity else { return false }
        guard let lastAttemptAt else { return true }
        guard now >= lastAttemptAt else { return false }
        return now.timeIntervalSince(lastAttemptAt) >= retryInterval
    }
}

/// Learns the phone's current BLE address without any foreground app or
/// network session, by challenging it over GATT.
///
/// iOS rotates the advertised address every few minutes, and every rotation
/// looks like a brand-new peripheral to the Mac. The foreground identity claim
/// only covers the moment PilotNest is open with an authenticated session,
/// which is exactly when the user does not need proximity unlock. This scanner
/// runs beside the monitoring scanner: it finds anything advertising the
/// PilotNest service, asks it to prove the pairing key, and hands the verified
/// address to the BLE Unlock model as just another alias.
@MainActor
final class BLEPresenceAuthenticator: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    struct Binding: Equatable {
        let clientID: String
        let keyFingerprint: String
    }

    var bindingProvider: @MainActor () -> [Binding] = { [] }
    var pairingKeyProvider: @MainActor (String) -> Data? = { _ in nil }
    var macIDProvider: @MainActor () -> UUID? = { nil }
    var isMonitored: @MainActor (UUID) -> Bool = { _ in true }
    var onAuthenticated: @MainActor (_ clientID: String, _ keyFingerprint: String, _ peripheralUUID: UUID) -> Void = { _, _, _ in }
    var onLog: @MainActor (String) -> Void = { _ in }

    private(set) var isActive = false
    private var manager: CBCentralManager?
    private var attempt: Attempt?
    private var attemptTimer: BackgroundTask?
    private var rescanTimer: BackgroundTask?
    private var lastAttemptAt: [UUID: Date] = [:]

    private let attemptTimeout: TimeInterval = 10
    /// Keeps the deduplicated scan from hiding a phone whose address was
    /// rejected before the retry interval elapsed.
    private let rescanInterval: TimeInterval = 60

    private struct Attempt {
        let peripheral: CBPeripheral
        let challenge: RemoteBLEPresenceChallenge
    }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        if active {
            onLog("identity authentication active")
            if manager == nil {
                manager = CBCentralManager(
                    delegate: self,
                    queue: .main,
                    options: [CBCentralManagerOptionShowPowerAlertKey: false]
                )
            }
            beginScan()
            startRescanTimer()
        } else {
            teardown()
        }
    }

    func shutdown() {
        isActive = false
        teardown()
    }

    private func log(_ message: @autoclosure () -> String) {
        onLog(message())
    }

    private func beginScan() {
        guard isActive, attempt == nil, let manager, manager.state == .poweredOn else { return }
        guard !bindingProvider().isEmpty, macIDProvider() != nil else { return }
        guard !manager.isScanning else { return }
        manager.scanForPeripherals(withServices: [RemoteBLEService.serviceUUID], options: nil)
    }

    private func startRescanTimer() {
        guard rescanTimer == nil else { return }
        rescanTimer = BackgroundTask.repeating(every: rescanInterval) { [weak self] in
            guard let self, self.isActive, self.attempt == nil, let manager = self.manager else { return }
            manager.stopScan()
            self.beginScan()
        }
    }

    private func teardown() {
        log("identity authentication inactive")
        attemptTimer?.stop()
        attemptTimer = nil
        rescanTimer?.stop()
        rescanTimer = nil
        if let peripheral = attempt?.peripheral {
            manager?.cancelPeripheralConnection(peripheral)
            peripheral.delegate = nil
        }
        attempt = nil
        manager?.stopScan()
        manager?.delegate = nil
        manager = nil
        lastAttemptAt.removeAll()
    }

    /// A new observation of an address nobody has challenged yet.
    func handleDiscovery(peripheral: CBPeripheral, rssi: Int, now: Date = Date()) {
        guard isActive, attempt == nil, let manager, manager.state == .poweredOn else { return }
        let uuid = peripheral.identifier
        let bindings = bindingProvider()
        let macID = macIDProvider()
        guard BLEPresenceAuthenticationPolicy.shouldAttempt(
            isMonitored: isMonitored(uuid),
            hasBindings: !bindings.isEmpty,
            hasMacIdentity: macID != nil,
            lastAttemptAt: lastAttemptAt[uuid],
            now: now
        ), let macID else { return }

        lastAttemptAt = lastAttemptAt.filter { now.timeIntervalSince($0.value) < 600 }
        lastAttemptAt[uuid] = now
        manager.stopScan()
        peripheral.delegate = self
        attempt = Attempt(
            peripheral: peripheral,
            challenge: RemoteBLEPresenceChallenge(macID: macID)
        )
        log("authenticating rotated phone address uuid=\(uuid.uuidString) rssi=\(rssi)")
        manager.connect(peripheral)
        scheduleAttemptTimeout()
    }

    private func scheduleAttemptTimeout() {
        attemptTimer?.stop()
        attemptTimer = BackgroundTask.once(after: attemptTimeout) { [weak self] in
            guard let self, let attempt = self.attempt else { return }
            self.attemptTimer = nil
            self.log("identity authentication timed out uuid=\(attempt.peripheral.identifier.uuidString)")
            self.finishAttempt()
        }
    }

    private func finishAttempt() {
        attemptTimer?.stop()
        attemptTimer = nil
        guard let attempt else {
            beginScan()
            return
        }
        self.attempt = nil
        if attempt.peripheral.state != .disconnected {
            manager?.cancelPeripheralConnection(attempt.peripheral)
        }
        attempt.peripheral.delegate = nil
        beginScan()
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === manager, isActive else { return }
        switch central.state {
        case .poweredOn:
            beginScan()
        case .unauthorized:
            log("identity authentication unavailable: Bluetooth unauthorized")
        case .unsupported:
            log("identity authentication unavailable: Bluetooth unsupported")
        case .poweredOff:
            log("identity authentication waiting for Bluetooth")
        default:
            break
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard central === manager else { return }
        handleDiscovery(peripheral: peripheral, rssi: RSSI.intValue)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === manager, attempt?.peripheral === peripheral else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverServices([RemoteBLEService.serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard central === manager, attempt?.peripheral === peripheral else { return }
        log("identity authentication connection failed uuid=\(peripheral.identifier.uuidString) error=\(error?.localizedDescription ?? "unknown")")
        finishAttempt()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard central === manager, attempt?.peripheral === peripheral else { return }
        finishAttempt()
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard attempt?.peripheral === peripheral else { return }
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == RemoteBLEService.serviceUUID }) else {
            log("identity authentication service lookup failed uuid=\(peripheral.identifier.uuidString) error=\(error?.localizedDescription ?? "not found")")
            finishAttempt()
            return
        }
        peripheral.discoverCharacteristics([RemoteBLEService.presenceChallengeCharacteristicUUID], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard attempt?.peripheral === peripheral else { return }
        guard error == nil,
              let characteristic = service.characteristics?.first(where: {
                  $0.uuid == RemoteBLEService.presenceChallengeCharacteristicUUID
              }) else {
            // An older PilotNest cannot answer. Its foreground claim path is
            // still available, so this is a normal miss, not an error.
            log("identity authentication skipped uuid=\(peripheral.identifier.uuidString) reason=phoneDoesNotChallenge")
            finishAttempt()
            return
        }
        guard let challenge = attempt?.challenge else {
            finishAttempt()
            return
        }
        peripheral.writeValue(challenge.encoded, for: characteristic, type: .withResponse)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard attempt?.peripheral === peripheral,
              characteristic.uuid == RemoteBLEService.presenceChallengeCharacteristicUUID else { return }
        if let error {
            log("identity authentication write failed uuid=\(peripheral.identifier.uuidString) error=\(error.localizedDescription)")
            finishAttempt()
            return
        }
        peripheral.readValue(for: characteristic)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard attempt?.peripheral === peripheral,
              characteristic.uuid == RemoteBLEService.presenceChallengeCharacteristicUUID,
              let attempt = attempt else { return }
        guard error == nil, let response = characteristic.value, !response.isEmpty else {
            log("identity authentication refused uuid=\(peripheral.identifier.uuidString) error=\(error?.localizedDescription ?? "no response")")
            finishAttempt()
            return
        }
        let binding = bindingProvider().first { binding in
            guard let key = pairingKeyProvider(binding.clientID) else { return false }
            return attempt.challenge.isValidResponse(response, pairingKey: key)
        }
        guard let binding else {
            log("identity authentication rejected uuid=\(peripheral.identifier.uuidString) reason=noMatchingPairingKey")
            finishAttempt()
            return
        }
        log("rotated phone address authenticated uuid=\(peripheral.identifier.uuidString) client=\(binding.clientID)")
        onAuthenticated(binding.clientID, binding.keyFingerprint, peripheral.identifier)
        finishAttempt()
    }
}
