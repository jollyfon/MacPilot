import CoreBluetooth
import Foundation
import MacPilotRemoteTransport

/// Advertises a plain GATT service so the reversed BLE roles can be measured.
///
/// Every other BLE path in this repo has the Mac as the central. Before building
/// background discovery, authentication or unlock on top of Mac-as-peripheral,
/// this harness has to prove the radio path exists at all: advertise, accept a
/// phone connection, answer a read, accept a notification subscription and echo
/// sixteen bytes back. It deliberately has no identity, no proximity verdict and
/// no unlock wiring, so a failure here cannot be mistaken for a security result.
@MainActor
final class ProximityBLEPeripheral: NSObject, ObservableObject, @preconcurrency CBPeripheralManagerDelegate {
    enum Status: Equatable {
        case idle
        case starting
        case advertising
        case connected
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var logLines: [String] = []
    @Published private(set) var lastEchoAt: Date?

    private var manager: CBPeripheralManager?
    private var macInfo = Data()
    private var publishedService: CBMutableService?
    private var echoCharacteristic: CBMutableCharacteristic?
    private var responseCharacteristic: CBMutableCharacteristic?
    private var subscribedCentrals: [UUID] = []
    private var wantsToRun = false
    private var isPublishing = false
    /// Echo that could not be queued because the notification buffer was full.
    /// `peripheralManagerIsReady(toUpdateSubscribers:)` retries it.
    private var pendingEcho: Data?
    private let logLimit = 200

    var isRunning: Bool {
        switch status {
        case .idle, .failed: return false
        default: return true
        }
    }

    // MARK: - Lifecycle

    func start(macDeviceID: UUID?) {
        if manager != nil { stop() }
        wantsToRun = true
        status = .starting
        lastEchoAt = nil
        macInfo = ProximityGATTMacInfo(deviceID: macDeviceID).encoded
        log("peripheral starting; MacID=\(macDeviceID?.uuidString ?? "not configured")")
        manager = CBPeripheralManager(
            delegate: self,
            queue: .main,
            options: [CBPeripheralManagerOptionShowPowerAlertKey: false]
        )
    }

    func stop() {
        wantsToRun = false
        pendingEcho = nil
        subscribedCentrals.removeAll()
        publishedService = nil
        echoCharacteristic = nil
        responseCharacteristic = nil
        isPublishing = false
        if let manager {
            manager.stopAdvertising()
            manager.removeAllServices()
            manager.delegate = nil
        }
        manager = nil
        status = .idle
        log("peripheral stopped")
    }

    // MARK: - GATT

    private func publishService(on manager: CBPeripheralManager) {
        guard wantsToRun, !isPublishing, publishedService == nil, manager.state == .poweredOn else { return }
        isPublishing = true

        let macInfoCharacteristic = CBMutableCharacteristic(
            type: ProximityGATTService.macInfoCharacteristicUUID,
            properties: [.read],
            value: macInfo,
            permissions: [.readable]
        )
        let echo = CBMutableCharacteristic(
            type: ProximityGATTService.echoCharacteristicUUID,
            properties: [.notify],
            value: nil,
            permissions: []
        )
        let response = CBMutableCharacteristic(
            type: ProximityGATTService.responseCharacteristicUUID,
            properties: [.write],
            value: nil,
            permissions: [.writeable]
        )
        let service = CBMutableService(type: ProximityGATTService.serviceUUID, primary: true)
        service.characteristics = [macInfoCharacteristic, echo, response]
        publishedService = service
        echoCharacteristic = echo
        responseCharacteristic = response
        log("publishing GATT service \(ProximityGATTService.serviceUUID.uuidString)")
        manager.add(service)
    }

    private func startAdvertising(_ manager: CBPeripheralManager) {
        guard wantsToRun else { return }
        // Service UUID only; the local name is optional for discovery and would
        // shrink the room left for the UUID in the legacy advertising payload.
        manager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [ProximityGATTService.serviceUUID]
        ])
    }

    private func log(_ message: @autoclosure () -> String) {
        let line = "\(Date.now.formatted(date: .omitted, time: .standard)) \(message())"
        logLines.append(line)
        if logLines.count > logLimit {
            logLines.removeFirst(logLines.count - logLimit)
        }
    }

    private func fail(_ reason: String) {
        status = .failed(reason)
        log("peripheral failed: \(reason)")
    }

    // MARK: - CBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral === manager else { return }
        switch peripheral.state {
        case .poweredOn:
            log("radio on")
            if wantsToRun { status = .starting }
            publishService(on: peripheral)
        case .unauthorized:
            fail("Bluetooth unauthorized")
        case .unsupported:
            fail("Bluetooth unsupported")
        case .poweredOff:
            resetPublishedService()
            fail("Bluetooth is off")
        default:
            resetPublishedService()
            log("waiting for Bluetooth state=\(peripheral.state.rawValue)")
        }
    }

    /// A radio that leaves the powered-on state drops its GATT registrations.
    /// Clearing the references lets the next powered-on callback publish them
    /// again; keeping them made a Bluetooth toggle leave the harness dead.
    private func resetPublishedService() {
        publishedService = nil
        echoCharacteristic = nil
        responseCharacteristic = nil
        isPublishing = false
        pendingEcho = nil
        subscribedCentrals.removeAll()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard peripheral === manager, service === publishedService else { return }
        isPublishing = false
        if let error {
            publishedService = nil
            fail("service add failed: \(error.localizedDescription)")
            return
        }
        log("GATT service added; starting advertisement")
        startAdvertising(peripheral)
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        guard peripheral === manager else { return }
        if let error {
            fail("advertising failed: \(error.localizedDescription)")
            return
        }
        guard wantsToRun else {
            peripheral.stopAdvertising()
            return
        }
        status = .advertising
        log("advertising started")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard peripheral === manager, request.characteristic.uuid == ProximityGATTService.macInfoCharacteristicUUID else {
            peripheral.respond(to: request, withResult: .requestNotSupported)
            return
        }
        guard request.offset == 0 else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = macInfo
        log("central read Mac info (\(macInfo.count) bytes)")
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            guard peripheral === manager,
                  request.characteristic.uuid == ProximityGATTService.responseCharacteristicUUID else {
                peripheral.respond(to: request, withResult: .requestNotSupported)
                continue
            }
            guard request.offset == 0,
                  let value = request.value,
                  value.count == ProximityGATTEcho.length else {
                log("rejected response write: offset=\(request.offset) bytes=\(request.value?.count ?? 0)")
                peripheral.respond(to: request, withResult: .invalidAttributeValueLength)
                continue
            }
            lastEchoAt = .now
            deliverEcho(value, on: peripheral)
            peripheral.respond(to: request, withResult: .success)
        }
    }

    private func deliverEcho(_ value: Data, on peripheral: CBPeripheralManager) {
        guard let echoCharacteristic else { return }
        guard peripheral.updateValue(value, for: echoCharacteristic, onSubscribedCentrals: nil) else {
            // No subscriber, or the notification queue is full. Keeping the
            // payload lets the ready callback retry instead of silently
            // dropping the phone's only liveness signal.
            pendingEcho = value
            log("echo not queued; waiting for the notification buffer")
            return
        }
        pendingEcho = nil
        log("echoed \(value.count) bytes to \(subscribedCentrals.count) subscriber(s)")
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        guard peripheral === manager, let pendingEcho else { return }
        log("notification buffer ready; retrying echo")
        deliverEcho(pendingEcho, on: peripheral)
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        guard peripheral === manager,
              characteristic.uuid == ProximityGATTService.echoCharacteristicUUID else { return }
        if !subscribedCentrals.contains(central.identifier) {
            subscribedCentrals.append(central.identifier)
        }
        status = .connected
        log("central subscribed uuid=\(central.identifier.uuidString)")
        // A peripheral stops advertising while a central is connected; keep the
        // intent so the link returns after this phone leaves.
        if peripheral.isAdvertising == false {
            log("advertisement paused while connected")
        }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        guard peripheral === manager,
              characteristic.uuid == ProximityGATTService.echoCharacteristicUUID else { return }
        subscribedCentrals.removeAll { $0 == central.identifier }
        log("central unsubscribed uuid=\(central.identifier.uuidString)")
        if subscribedCentrals.isEmpty {
            if !wantsToRun {
                status = .idle
            } else {
                status = peripheral.isAdvertising ? .advertising : .starting
            }
        }
        if wantsToRun, peripheral.state == .poweredOn, peripheral.isAdvertising == false {
            startAdvertising(peripheral)
        }
    }
}
