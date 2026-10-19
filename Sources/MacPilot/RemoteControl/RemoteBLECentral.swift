import CoreBluetooth
import Foundation
import MacPilotRemoteProtocol
import MacPilotRemoteTransport

/// Finds the phone over BLE and opens a stream-oriented L2CAP channel to it.
///
/// This is the fallback link: it needs no router, no shared subnet and no
/// peer-to-peer Wi-Fi, so it covers the cases the network path cannot — a Mac on
/// Ethernet, a phone on cellular, a client-isolating guest network.
///
/// The Mac is deliberately the central here. That is the direction BLE actually
/// supports between these two devices: this Mac already holds a central link to
/// the iPhone for hours at a time for the proximity unlock, while the opposite
/// direction — Mac advertising, phone connecting — never establishes a
/// connection at all.
///
/// Scanning is cheap on a machine that is plugged in, and the phone only
/// advertises when it actually wants the fallback, so nothing is connected
/// speculatively.
@MainActor
final class RemoteBLECentral: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    /// Hands a newly opened channel to the remote control server.
    var onChannel: ((CBL2CAPChannel, UUID) -> Void)?
    /// Reports a peripheral whose GATT identity characteristic matched the
    /// token an authenticated network client registered: (peripheral UUID,
    /// client ID, pairing-key fingerprint).
    var onIdentityClaim: ((UUID, String, String) -> Void)?
    var onLog: ((String) -> Void)?

    private struct PendingIdentityClaim {
        let clientID: String
        let keyFingerprint: String
        let expiresAt: Date
    }

    private var manager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var psmCharacteristic: CBCharacteristic?
    /// Claims waiting for a matching advertisement, keyed by the random token.
    /// A claim is single use and expires with the phone's probe window.
    private var pendingIdentityClaims: [Data: PendingIdentityClaim] = [:]
    private var isScanning = false
    private var wantsToRun = false
    private var attemptWatchdog: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var channelOpenRetryPolicy = RemoteBLEChannelOpenRetryPolicy()

    /// How long a single discovery attempt may take before it is restarted.
    /// Connecting, discovering and opening a channel are each a round trip, and
    /// a stalled step would otherwise leave the fallback silently dead.
    private let attemptTimeout: TimeInterval = 12

    /// Consecutive attempts that timed out without even discovering the phone.
    /// Drives the exponential backoff so a wedged radio or an absent phone
    /// cannot turn the fallback into a permanent twelve-second restart churn.
    private var consecutiveStalls = 0

    /// Backoff series for stalled attempts: the base timeout doubles with each
    /// consecutive stall and is capped so a long outage still retries, just
    /// quietly. Any progress (discovery, connection, channel) resets the count.
    nonisolated static func backoffTimeout(base: TimeInterval, stallCount: Int, cap: TimeInterval = 300) -> TimeInterval {
        guard stallCount > 0 else { return base }
        // The phone only advertises when it wants the fallback, so an idle
        // miss is the normal case and the very first retry must already slow
        // down; only a fresh attempt after progress earns the base timeout.
        let exponent = min(stallCount, 8)
        return min(base * pow(2.0, Double(exponent)), cap)
    }

    private var currentAttemptTimeout: TimeInterval {
        Self.backoffTimeout(base: attemptTimeout, stallCount: consecutiveStalls)
    }

    // MARK: - Lifecycle

    func start() {
        wantsToRun = true
        if manager == nil {
            onLog?("BLE central starting")
            manager = CBCentralManager(
                delegate: self,
                queue: .main,
                options: [CBCentralManagerOptionShowPowerAlertKey: false]
            )
            return
        }
        beginScanningIfPossible()
    }

    func stop() {
        wantsToRun = false
        consecutiveStalls = 0
        attemptWatchdog?.cancel()
        attemptWatchdog = nil
        retryTask?.cancel()
        retryTask = nil
        channelOpenRetryPolicy = RemoteBLEChannelOpenRetryPolicy()
        isScanning = false
        manager?.stopScan()
        if let peripheral {
            manager?.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        psmCharacteristic = nil
        pendingIdentityClaims.removeAll()
        // Release the radio session as well. Keeping the manager alive after the
        // feature is switched off would leave an idle CBCentralManager, its
        // delegate graph and its connection to bluetoothd around for the rest of
        // the process; `start()` rebuilds it on the next enable.
        manager?.delegate = nil
        manager = nil
    }

    /// A network-authenticated peer is about to open its bounded BLE identity
    /// probe. Start a fresh attempt now and drop a backoff that was earned
    /// while no phone was advertising, so the probe does not have to out-wait
    /// a long idle interval.
    func armForIdentityProbe() {
        guard wantsToRun, peripheral == nil else { return }
        consecutiveStalls = 0
        retryTask?.cancel()
        retryTask = nil
        resetAttempt()
    }

    /// Registers the token an authenticated client published for its BLE
    /// identity characteristic and makes sure an attempt is running to read it.
    func expectIdentityClaim(
        token: Data,
        validity: TimeInterval,
        clientID: String,
        keyFingerprint: String
    ) {
        pruneExpiredIdentityClaims()
        let bounded = min(max(validity, 1), RemoteBLEIdentityClaim.maximumValidity)
        pendingIdentityClaims[token] = PendingIdentityClaim(
            clientID: clientID,
            keyFingerprint: keyFingerprint,
            expiresAt: Date().addingTimeInterval(bounded)
        )
        onLog?("BLE identity claim registered validity=\(Int(bounded))s; reading the claim on discovery")
        armForIdentityProbe()
    }

    private func pruneExpiredIdentityClaims() {
        let now = Date()
        pendingIdentityClaims = pendingIdentityClaims.filter { $0.value.expiresAt > now }
    }

    // MARK: - Discovery

    private func beginScanningIfPossible() {
        // Every early return names its reason. A silent return here is
        // indistinguishable from a healthy scan, which is exactly how a fallback
        // that never connects stays invisible.
        guard wantsToRun else {
            onLog?("BLE idle; the fallback is not needed")
            return
        }
        guard retryTask == nil else { return }
        guard let manager else {
            onLog?("BLE waiting for the central manager")
            return
        }
        guard manager.state == .poweredOn else {
            onLog?("BLE waiting for Bluetooth: state=\(manager.state.rawValue)")
            return
        }
        guard !isScanning, peripheral == nil else { return }
        isScanning = true
        onLog?("BLE scanning for the phone")
        manager.scanForPeripherals(withServices: [RemoteBLEService.serviceUUID])
        armWatchdog()
    }

    /// Restarts discovery if the current attempt stalls mid-handshake.
    private func armWatchdog() {
        attemptWatchdog?.cancel()
        attemptWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.currentAttemptTimeout ?? 12))
            guard let self, !Task.isCancelled, self.wantsToRun else { return }
            self.consecutiveStalls += 1
            self.onLog?("BLE attempt stalled; restarting discovery timeout=\(Int(self.currentAttemptTimeout))s stalls=\(self.consecutiveStalls)")
            self.resetAttempt()
        }
    }

    private func resetAttempt() {
        attemptWatchdog?.cancel()
        attemptWatchdog = nil
        isScanning = false
        manager?.stopScan()
        if let peripheral {
            manager?.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        psmCharacteristic = nil
        beginScanningIfPossible()
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // The raw state is logged on every transition, including the ones that
        // have no dedicated case: a powered-off radio used to fall into
        // `default` and leave no trace at all.
        onLog?("BLE central state=\(central.state.rawValue)")
        switch central.state {
        case .poweredOn:
            beginScanningIfPossible()
        case .unauthorized:
            onLog?("BLE unauthorized; the Bluetooth permission is required for the fallback link")
        case .unsupported:
            onLog?("BLE unsupported on this Mac")
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
        guard wantsToRun, self.peripheral == nil else { return }
        consecutiveStalls = 0
        self.peripheral = peripheral
        peripheral.delegate = self
        central.stopScan()
        isScanning = false
        // The UUID distinguishes two paired Apple devices advertising the same
        // service; without it a failed service lookup cannot be attributed.
        onLog?("BLE found the phone; connecting uuid=\(peripheral.identifier.uuidString) name=\(peripheral.name ?? "unknown") rssi=\(RSSI.intValue)")
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard wantsToRun, self.peripheral === peripheral else { return }
        peripheral.discoverServices([RemoteBLEService.serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard wantsToRun, self.peripheral === peripheral else { return }
        onLog?("BLE connect failed uuid=\(peripheral.identifier.uuidString) error=\(error?.localizedDescription ?? "unknown")")
        resetAttempt()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        // A disconnect is only a problem while we still need a channel; once one
        // is open the L2CAP stream outlives this callback's caller. The phone
        // stops advertising as soon as it is back on the network, so closing
        // here is expected and must not be logged as a failure.
        guard wantsToRun, self.peripheral === peripheral else { return }
        // Leaving no trace here made a dropped link indistinguishable from a
        // scan that never found anything.
        onLog?("BLE disconnected uuid=\(peripheral.identifier.uuidString) error=\(error?.localizedDescription ?? "none"); rescanning")
        resetAttempt()
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard wantsToRun, self.peripheral === peripheral else { return }
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == RemoteBLEService.serviceUUID })
        else {
            onLog?("BLE service discovery failed uuid=\(peripheral.identifier.uuidString) error=\(error?.localizedDescription ?? "not found")")
            resetAttempt()
            return
        }
        // Discover both even when no claim is pending. An older phone simply
        // has no identity characteristic; asking costs one round trip and lets
        // a claim that arrived mid-connection still be honoured.
        peripheral.discoverCharacteristics(
            [RemoteBLEService.psmCharacteristicUUID, RemoteBLEService.identityClaimCharacteristicUUID],
            for: service
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard wantsToRun, self.peripheral === peripheral else { return }
        guard error == nil,
              let characteristic = service.characteristics?.first(where: { $0.uuid == RemoteBLEService.psmCharacteristicUUID })
        else {
            onLog?("BLE PSM characteristic missing uuid=\(peripheral.identifier.uuidString) error=\(error?.localizedDescription ?? "not found")")
            resetAttempt()
            return
        }
        psmCharacteristic = characteristic
        pruneExpiredIdentityClaims()
        if !pendingIdentityClaims.isEmpty,
           let claimCharacteristic = service.characteristics?.first(where: { $0.uuid == RemoteBLEService.identityClaimCharacteristicUUID }) {
            // Identity before channel: the claim is why this attempt exists,
            // and opening L2CAP for a phone that is merely claiming identity
            // would pay for a handshake this Mac does not need.
            onLog?("BLE reading identity claim uuid=\(peripheral.identifier.uuidString)")
            peripheral.readValue(for: claimCharacteristic)
            return
        }
        peripheral.readValue(for: characteristic)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard wantsToRun, self.peripheral === peripheral else { return }
        guard error == nil, let data = characteristic.value else {
            onLog?("BLE characteristic read failed uuid=\(peripheral.identifier.uuidString) error=\(error?.localizedDescription ?? "no value")")
            resetAttempt()
            return
        }
        if characteristic.uuid == RemoteBLEService.identityClaimCharacteristicUUID {
            handleIdentityClaimValue(data, peripheral: peripheral)
            return
        }
        guard characteristic.uuid == RemoteBLEService.psmCharacteristicUUID,
              let psm = RemoteBLEService.decodePSM(data) else {
            onLog?("BLE PSM read failed uuid=\(peripheral.identifier.uuidString) error=bad value")
            resetAttempt()
            return
        }
        onLog?("BLE opening L2CAP channel psm=\(psm)")
        peripheral.openL2CAPChannel(psm)
    }

    /// A GATT read of the token is enough to bind the peripheral UUID the Mac
    /// observes to the client that authenticated over the network. The claim is
    /// consumed on a match so a replayed read can never learn a second UUID.
    private func handleIdentityClaimValue(_ token: Data, peripheral: CBPeripheral) {
        pruneExpiredIdentityClaims()
        guard let match = pendingIdentityClaims.first(where: {
            RemoteCrypto.constantTimeEquals($0.key, token)
        }) else {
            onLog?("BLE identity claim mismatch uuid=\(peripheral.identifier.uuidString); continuing with L2CAP")
            if let psmCharacteristic {
                peripheral.readValue(for: psmCharacteristic)
            } else {
                resetAttempt()
            }
            return
        }
        pendingIdentityClaims.removeValue(forKey: match.key)
        let claim = match.value
        onLog?("BLE identity claim matched uuid=\(peripheral.identifier.uuidString); peripheral identity learned")
        onIdentityClaim?(peripheral.identifier, claim.clientID, claim.keyFingerprint)
        // The phone stops claiming once the Mac has read the token, but the
        // remote-control fallback still needs a scan running for the next time
        // the network goes away.
        resetAttempt()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didOpen channel: CBL2CAPChannel?,
        error: Error?
    ) {
        guard wantsToRun, self.peripheral === peripheral else {
            channel?.inputStream.close()
            channel?.outputStream.close()
            return
        }
        guard error == nil, let channel else {
            let delay = channelOpenRetryPolicy.recordOpenFailure()
            onLog?("BLE L2CAP open failed error=\(Self.errorSummary(error)); retrying in \(Int(delay))s")
            scheduleRetryAfterChannelOpenFailure(delay: delay)
            return
        }
        // The GATT link stays up: the L2CAP channel belongs to this peripheral,
        // so tearing the peripheral down would close the stream with it.
        attemptWatchdog?.cancel()
        attemptWatchdog = nil
        channelOpenRetryPolicy.recordOpenSuccess()
        onLog?("BLE L2CAP channel open")
        onChannel?(channel, peripheral.identifier)
    }

    private static func errorSummary(_ error: Error?) -> String {
        guard let error else { return "unknown" }
        let cocoaError = error as NSError
        let summary = "\(cocoaError.domain)/\(cocoaError.code): \(cocoaError.localizedDescription)"
        guard let underlying = cocoaError.userInfo[NSUnderlyingErrorKey] as? NSError else {
            return summary
        }
        return "\(summary); underlying=\(underlying.domain)/\(underlying.code)"
    }

    private func scheduleRetryAfterChannelOpenFailure(delay: TimeInterval) {
        attemptWatchdog?.cancel()
        attemptWatchdog = nil
        isScanning = false
        manager?.stopScan()
        if let peripheral {
            manager?.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        psmCharacteristic = nil

        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.wantsToRun else { return }
            self.retryTask = nil
            self.beginScanningIfPossible()
        }
    }
}
