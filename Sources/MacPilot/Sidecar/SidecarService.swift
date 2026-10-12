import Foundation
import MacPilotRemoteProtocol

/// Drives native Sidecar on behalf of the iPhone remote channel.
///
/// Three rules shape everything here:
///
/// - A connect is **accepted** immediately and its outcome travels as the
///   snapshot's operation phase. Bringing up a session takes longer than the
///   phone's RPC timeout, so waiting for it would report a timeout for a
///   session that is actually coming up.
/// - **Connected means the system says so.** Neither a completion block without
///   an error nor the fact that we asked is proof; every verdict is re-read from
///   the framework's own connected list before the phone is told anything.
/// - **No timer of our own.** Verdicts are settled when the state is read — by a
///   poll, or by the next request — rather than by a background watchdog. The
///   phone already asks once a second while an operation is on screen, so a
///   second polling loop here would only be a second thing to get wrong.
@MainActor
final class SidecarService: RemoteSidecarHosting {
    /// Long enough for an iPad to wake and negotiate a session, short enough
    /// that a "connecting" badge cannot outlive a session that died silently.
    static let defaultConnectTimeout: Duration = .seconds(45)
    static let defaultDisconnectTimeout: Duration = .seconds(15)

    /// Documented in SidecarCore as `SidecarErrorDeviceWiFiNotEnabled`: the iPad
    /// is listed but asleep, locked or off Wi-Fi, so it cannot take a session.
    static let deviceUnreachableErrorCode = -203

    private let bridge: any SidecarCoreBridge
    private let connectTimeout: Duration
    private let disconnectTimeout: Duration
    private let logHandler: (String) -> Void
    /// Injectable because a deadline nobody can move is a deadline a test has to
    /// wait for, and waiting on the main actor is exactly what a full test run
    /// cannot offer.
    private let now: @MainActor () -> ContinuousClock.Instant

    /// The operation in flight, or the last one that failed. `nil` when nothing
    /// is happening and no attempt is waiting to be explained.
    private var record: OperationRecord?
    private var operationTask: Task<Void, Never>?
    /// Bumped whenever an operation is replaced or concluded, so a late answer
    /// from an abandoned operation cannot overwrite the newer state.
    private var generation = 0

    /// The task driving the framework for the operation on record, or `nil` once
    /// that operation has been concluded.
    ///
    /// Awaiting a task that already exists needs no scheduler cooperation,
    /// while polling for its effect does — and on a shared main actor a poll has
    /// no guarantee of being scheduled at all.
    var pendingOperation: Task<Void, Never>? { operationTask }

    init(
        bridge: any SidecarCoreBridge = SidecarCoreRuntime(),
        connectTimeout: Duration = SidecarService.defaultConnectTimeout,
        disconnectTimeout: Duration = SidecarService.defaultDisconnectTimeout,
        now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now },
        log: @escaping (String) -> Void = { remoteControlLog($0) }
    ) {
        self.bridge = bridge
        self.connectTimeout = connectTimeout
        self.disconnectTimeout = disconnectTimeout
        self.now = now
        self.logHandler = log
    }

    private func log(_ message: @autoclosure () -> String) {
        logHandler(message())
    }

    // MARK: - RemoteSidecarHosting

    var isRemotelyAvailable: Bool { bridge.isSupported }

    func remoteSnapshot() -> RemoteSidecarSnapshot? {
        guard bridge.isSupported else { return nil }
        let state = bridge.currentState()
        settle(using: state)
        return snapshot(from: state)
    }

    func remoteConnect(deviceID: String) -> RemoteSidecarOutcome {
        guard bridge.isSupported else { return .failure(.sidecarUnavailable) }
        let state = bridge.currentState()
        settle(using: state)

        guard state.devices.contains(where: { $0.identifier == deviceID }) else {
            log("sidecar connect refused reason=deviceNotFound device=\(deviceID)")
            return .failure(.sidecarDeviceNotFound)
        }
        guard !state.connectedIdentifiers.contains(deviceID) else {
            log("sidecar connect refused reason=alreadyConnected device=\(deviceID)")
            return .failure(.sidecarAlreadyConnected)
        }
        guard !isBusy else {
            log("sidecar connect refused reason=operationInProgress device=\(deviceID)")
            return .failure(.sidecarOperationInProgress)
        }

        // Sidecar drives one iPad at a time, so switching targets ends the
        // current session inside the same operation. The phone is told
        // "accepted" now and watches the phase; it never waits on a teardown it
        // cannot time.
        let displaced = state.connectedIdentifiers.first { $0 != deviceID }
        beginOperation(
            deviceID: deviceID,
            displaced: displaced,
            intent: .connecting,
            timeout: connectTimeout
        )
        return .snapshot(snapshot(from: bridge.currentState()))
    }

    func remoteDisconnect(deviceID: String) -> RemoteSidecarOutcome {
        guard bridge.isSupported else { return .failure(.sidecarUnavailable) }
        let state = bridge.currentState()
        settle(using: state)

        let isConnected = state.connectedIdentifiers.contains(deviceID)
        guard isConnected || state.devices.contains(where: { $0.identifier == deviceID }) else {
            log("sidecar disconnect refused reason=deviceNotFound device=\(deviceID)")
            return .failure(.sidecarDeviceNotFound)
        }
        // Ahead of the "already down" answer below: a request that is ignored
        // must still be answered, and a snapshot carrying somebody else's
        // operation is not an answer to this one.
        guard !isBusy else {
            log("sidecar disconnect refused reason=operationInProgress device=\(deviceID)")
            return .failure(.sidecarOperationInProgress)
        }
        // Already down: answering with the real list beats an error the phone
        // would have to explain away.
        guard isConnected else { return .snapshot(snapshot(from: state)) }

        beginOperation(deviceID: deviceID, displaced: nil, intent: .disconnecting, timeout: disconnectTimeout)
        return .snapshot(snapshot(from: bridge.currentState()))
    }

    // MARK: - Operation state

    private struct OperationRecord {
        let deviceID: String
        /// What was asked for. Kept after a failure so a stale verdict can be
        /// recognised: a failed connect on a device that is connected now says
        /// something the system has since contradicted.
        let intent: RemoteSidecarPhase
        /// The displaced session a target switch has to end first.
        let displaced: String?
        /// Past this instant an unconfirmed operation is reported as a timeout
        /// by whoever reads the state next.
        let deadline: ContinuousClock.Instant
        var errorCode: RemoteErrorCode?

        var isFailed: Bool { errorCode != nil }

        var wireOperation: RemoteSidecarOperation {
            RemoteSidecarOperation(
                deviceID: deviceID,
                phase: isFailed ? .failed : intent,
                errorCode: errorCode
            )
        }
    }

    private var isBusy: Bool {
        guard let record else { return false }
        return !record.isFailed
    }

    private func snapshot(from state: SidecarBridgeState) -> RemoteSidecarSnapshot {
        let connected = Set(state.connectedIdentifiers)
        return RemoteSidecarSnapshot(
            devices: state.devices.map { device in
                RemoteSidecarDevice(
                    id: device.identifier,
                    name: device.name,
                    model: device.model,
                    isConnected: connected.contains(device.identifier)
                )
            },
            operation: record?.wireOperation
        )
    }

    private func beginOperation(deviceID: String, displaced: String?, intent: RemoteSidecarPhase, timeout: Duration) {
        cancelOperation()
        generation += 1
        let current = generation
        record = OperationRecord(
            deviceID: deviceID,
            intent: intent,
            displaced: displaced,
            deadline: now().advanced(by: timeout)
        )
        log("sidecar operation started intent=\(intent.rawValue) device=\(deviceID) displaced=\(displaced ?? "-")")

        operationTask = Task { [weak self] in
            guard let self else { return }
            let error = await self.perform(deviceID: deviceID, displaced: displaced, intent: intent)
            guard self.generation == current else { return }
            if let error {
                self.log("sidecar framework refused intent=\(intent.rawValue) device=\(deviceID) error=\(error)")
                self.fail(deviceID: deviceID, intent: intent, code: Self.wireCode(for: error, intent: intent))
                return
            }
            // No error is not a verdict yet: the session has to appear in the
            // system's own list. If it is not there yet the phone's next poll
            // reads it and settles the record then.
            self.settle(using: self.bridge.currentState())
        }
    }

    private func perform(deviceID: String, displaced: String?, intent: RemoteSidecarPhase) async -> SidecarBridgeError? {
        switch intent {
        case .connecting:
            if let displaced, let error = await bridge.disconnect(deviceID: displaced) {
                log("sidecar switch could not end the previous session device=\(displaced) error=\(error)")
                return error
            }
            return await bridge.connect(deviceID: deviceID)
        case .disconnecting:
            return await bridge.disconnect(deviceID: deviceID)
        case .failed:
            return nil
        }
    }

    /// Turns the framework's own state into a verdict for the operation on
    /// record. Called on every read — a poll, the next target request, or the
    /// operation task itself — so nothing here depends on being woken up.
    ///
    /// A timeout is only reported after the real session list has been read
    /// again, so a session that did come up is never announced as a failure;
    /// and a failure the system has since contradicted (the user connected from
    /// the Mac, or the session ended on its own) goes away instead of being
    /// repeated on every poll.
    private func settle(using state: SidecarBridgeState) {
        guard let record else { return }
        let isConnected = state.connectedIdentifiers.contains(record.deviceID)
        let goalReached = record.intent == .connecting ? isConnected : !isConnected

        if record.isFailed {
            guard goalReached else { return }
            log("sidecar stale failure cleared device=\(record.deviceID)")
            conclude(nil)
            return
        }
        if goalReached {
            succeed(deviceID: record.deviceID, intent: record.intent)
            return
        }
        guard now() >= record.deadline else { return }
        log("sidecar operation timed out intent=\(record.intent.rawValue) device=\(record.deviceID)")
        fail(deviceID: record.deviceID, intent: record.intent, code: .commandTimeout)
    }

    private func succeed(deviceID: String, intent: RemoteSidecarPhase) {
        log("sidecar \(intent.rawValue) confirmed by the system device=\(deviceID)")
        conclude(nil)
    }

    private func fail(deviceID: String, intent: RemoteSidecarPhase, code: RemoteErrorCode) {
        // The record keeps its intent, so the wire reports `.failed` while the
        // healing rule still knows what was asked for.
        record?.errorCode = code
        generation += 1
        cancelOperation()
        log("sidecar \(intent.rawValue) failed device=\(deviceID) code=\(code.rawValue)")
    }

    /// Replaces the operation in flight (or clears it) and invalidates the task,
    /// so nothing that is still awaiting the framework can write over the new
    /// state.
    private func conclude(_ newRecord: OperationRecord?) {
        generation += 1
        cancelOperation()
        record = newRecord
    }

    private func cancelOperation() {
        operationTask?.cancel()
        operationTask = nil
    }

    private static func wireCode(for error: SidecarBridgeError, intent: RemoteSidecarPhase) -> RemoteErrorCode {
        switch error {
        case .unsupported:
            return .sidecarUnavailable
        case .deviceMissing:
            return .sidecarDeviceNotFound
        case .refused(_, let code) where code == deviceUnreachableErrorCode:
            return .sidecarDeviceUnreachable
        case .refused:
            return intent == .connecting ? .sidecarConnectFailed : .sidecarDisconnectFailed
        }
    }
}
