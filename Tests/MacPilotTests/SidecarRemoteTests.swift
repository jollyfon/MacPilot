import Foundation
import MacPilotRemoteProtocol
import Testing
@testable import MacPilot

/// A stand-in for the private framework.
///
/// The point of the lag is that the real `SidecarCore` answers its completion
/// block before the session shows up in `-connectedDevices`, and the service is
/// built to distrust exactly that gap. It counts state reads, the operation's
/// own verification read included, so a lag of 2 leaves one unconfirmed read for
/// the test to observe. `Int.max` models a session that never arrives, which is
/// how a timeout is produced without a real iPad.
@MainActor
private final class StubSidecarBridge: SidecarCoreBridge {
    var isSupported: Bool
    var state: SidecarBridgeState
    var connectError: SidecarBridgeError?
    var disconnectError: SidecarBridgeError?
    var confirmationLag: Int
    private(set) var connects: [String] = []
    private(set) var disconnects: [String] = []
    private var queue: [(deviceID: String, connect: Bool)] = []
    private var lagRemaining = 0

    init(
        isSupported: Bool = true,
        devices: [SidecarBridgeDevice] = [],
        connected: [String] = [],
        confirmationLag: Int = 0
    ) {
        self.isSupported = isSupported
        self.state = SidecarBridgeState(
            isSupported: isSupported,
            devices: devices,
            connectedIdentifiers: connected
        )
        self.confirmationLag = confirmationLag
    }

    func currentState() -> SidecarBridgeState {
        if !queue.isEmpty {
            if lagRemaining > 0 {
                lagRemaining -= 1
            } else {
                apply(queue.removeFirst())
            }
        }
        return state
    }

    func connect(deviceID: String) async -> SidecarBridgeError? {
        connects.append(deviceID)
        if let connectError { return connectError }
        queue.append((deviceID, true))
        lagRemaining = confirmationLag
        return nil
    }

    func disconnect(deviceID: String) async -> SidecarBridgeError? {
        disconnects.append(deviceID)
        if let disconnectError { return disconnectError }
        queue.append((deviceID, false))
        lagRemaining = confirmationLag
        return nil
    }

    private func apply(_ change: (deviceID: String, connect: Bool)) {
        var connected = state.connectedIdentifiers
        if change.connect {
            if !connected.contains(change.deviceID) { connected.append(change.deviceID) }
        } else {
            connected.removeAll { $0 == change.deviceID }
        }
        state = SidecarBridgeState(
            isSupported: state.isSupported,
            devices: state.devices,
            connectedIdentifiers: connected
        )
    }
}

@Suite("Sidecar service")
@MainActor
struct SidecarServiceTests {
    private static let ipad = SidecarBridgeDevice(identifier: "ipad-1", name: "iPad", model: "iPad16,1")
    private static let studio = SidecarBridgeDevice(identifier: "ipad-2", name: "Studio", model: nil)

    /// A clock the test moves. The service reads every deadline through it, so a
    /// timeout is a value the test sets instead of wall time it has to wait out
    /// on the shared main actor — where a full run gives it no guarantee of
    /// being scheduled at all.
    @MainActor
    private final class ManualClock {
        private(set) var instant = ContinuousClock.now
        func advance(by duration: Duration) { instant = instant.advanced(by: duration) }
    }

    private func makeService(
        bridge: StubSidecarBridge,
        clock: ManualClock? = nil,
        connectTimeout: Duration = SidecarService.defaultConnectTimeout,
        disconnectTimeout: Duration = SidecarService.defaultDisconnectTimeout
    ) -> SidecarService {
        let clock = clock ?? ManualClock()
        return SidecarService(
            bridge: bridge,
            connectTimeout: connectTimeout,
            disconnectTimeout: disconnectTimeout,
            now: { clock.instant },
            log: { _ in }
        )
    }

    private func snapshot(_ service: SidecarService) throws -> RemoteSidecarSnapshot {
        try #require(service.remoteSnapshot())
    }

    /// Runs the dispatched framework calls to completion.
    ///
    /// Awaiting a task the service already created is exact: no sleep to
    /// outlast, no poll hoping to be scheduled between somebody else's work.
    /// Every handle is taken before the first suspension, because an operation
    /// that concludes drops its own.
    private func drain(_ services: SidecarService...) async throws {
        let tasks = try services.map { service in try #require(service.pendingOperation) }
        for task in tasks { await task.value }
    }

    // MARK: - Availability

    @Test func aMacWithoutSidecarOffersNothingAndRefusesBothTargets() {
        let bridge = StubSidecarBridge(isSupported: false, devices: [Self.ipad])
        let service = makeService(bridge: bridge)
        #expect(!service.isRemotelyAvailable)
        // The router turns this `nil` into `unsupportedCommand`, which is what
        // keeps an old phone's unknown-command path from ever being reached.
        #expect(service.remoteSnapshot() == nil)
        #expect(service.remoteConnect(deviceID: Self.ipad.identifier) == .failure(.sidecarUnavailable))
        #expect(service.remoteDisconnect(deviceID: Self.ipad.identifier) == .failure(.sidecarUnavailable))
        #expect(bridge.connects.isEmpty)
        #expect(bridge.disconnects.isEmpty)
    }

    @Test func aSupportedMacListsEveryDeviceAndTakesItsConnectionStateFromTheSystemList() throws {
        let bridge = StubSidecarBridge(devices: [Self.ipad, Self.studio], connected: [Self.studio.identifier])
        let service = makeService(bridge: bridge)
        #expect(service.isRemotelyAvailable)
        let listed = try snapshot(service)
        #expect(listed.devices.map(\.id) == [Self.ipad.identifier, Self.studio.identifier])
        #expect(listed.devices.map(\.isConnected) == [false, true])
        #expect(listed.devices.first?.model == "iPad16,1")
        #expect(listed.connectedDevice?.id == Self.studio.identifier)
        #expect(listed.operation == nil)
    }

    // MARK: - Refusals

    @Test func aDeviceTheMacCannotSeeIsRefusedWithoutTouchingTheFramework() {
        let bridge = StubSidecarBridge(devices: [Self.ipad])
        let service = makeService(bridge: bridge)
        #expect(service.remoteConnect(deviceID: "gone") == .failure(.sidecarDeviceNotFound))
        #expect(service.remoteDisconnect(deviceID: "gone") == .failure(.sidecarDeviceNotFound))
        #expect(bridge.connects.isEmpty)
        #expect(bridge.disconnects.isEmpty)
    }

    @Test func anIPadThatIsAlreadyMirroringIsNotConnectedAgain() {
        let bridge = StubSidecarBridge(devices: [Self.ipad], connected: [Self.ipad.identifier])
        let service = makeService(bridge: bridge)
        #expect(service.remoteConnect(deviceID: Self.ipad.identifier) == .failure(.sidecarAlreadyConnected))
        #expect(bridge.connects.isEmpty)
    }

    /// Two phones, or one phone double-tapping, must not produce two sessions.
    @Test func aSecondOperationIsRefusedWhileOneIsStillLive() async throws {
        let bridge = StubSidecarBridge(
            devices: [Self.ipad, Self.studio],
            confirmationLag: .max
        )
        let service = makeService(bridge: bridge)
        guard case .snapshot = service.remoteConnect(deviceID: Self.ipad.identifier) else {
            Issue.record("the first connect must be accepted")
            return
        }
        #expect(service.remoteConnect(deviceID: Self.studio.identifier) == .failure(.sidecarOperationInProgress))
        #expect(service.remoteDisconnect(deviceID: Self.ipad.identifier) == .failure(.sidecarOperationInProgress))
        // The refusals are decided from the operation record, so they hold
        // before the accepted request has even reached the framework. Run that
        // request now: exactly one call arriving is what proves the other two
        // were refused rather than merely answered later.
        try await drain(service)
        #expect(bridge.connects == [Self.ipad.identifier])
        #expect(bridge.disconnects.isEmpty)
        #expect(try snapshot(service).operation?.phase == .connecting)
    }

    /// Already down is a fact, not a failure: the phone asked for the state it
    /// already has, and an error would make it explain away a healthy Mac.
    @Test func disconnectingAnIPadThatIsNotMirroringReportsTheListWithoutAnError() throws {
        let bridge = StubSidecarBridge(devices: [Self.ipad])
        let service = makeService(bridge: bridge)
        guard case let .snapshot(reported) = service.remoteDisconnect(deviceID: Self.ipad.identifier) else {
            Issue.record("an idle disconnect must answer with the list")
            return
        }
        #expect(reported.operation == nil)
        #expect(reported.devices.first?.isConnected == false)
        #expect(bridge.disconnects.isEmpty)
    }

    // MARK: - Accepted, then verified

    @Test func aConnectIsAcceptedBeforeTheSystemHasConfirmedIt() throws {
        let bridge = StubSidecarBridge(devices: [Self.ipad])
        let service = makeService(bridge: bridge)
        guard case let .snapshot(accepted) = service.remoteConnect(deviceID: Self.ipad.identifier) else {
            Issue.record("the connect must be accepted")
            return
        }
        // Bringing a session up outlasts the phone's RPC window, so the reply
        // means "accepted" — and it must not claim a connection that the
        // system's own list has not reported yet.
        #expect(accepted.operation?.deviceID == Self.ipad.identifier)
        #expect(accepted.operation?.phase == .connecting)
        #expect(accepted.operation?.errorCode == nil)
        #expect(accepted.devices.first?.isConnected == false)
        #expect(accepted.connectedDevice == nil)
    }

    @Test func aNilFrameworkErrorIsNotProofUntilTheConnectedListAgrees() async throws {
        // The framework returns without an error one read before the session
        // appears, which is the real order on a real Mac.
        let bridge = StubSidecarBridge(devices: [Self.ipad], confirmationLag: 2)
        let service = makeService(bridge: bridge)
        _ = service.remoteConnect(deviceID: Self.ipad.identifier)
        try await drain(service)
        // The call came back clean and the operation is still open: a
        // completion block without an error is not a verdict.
        #expect(try snapshot(service).operation?.phase == .connecting)
        // The read that finally sees the session in the system's own list is
        // the one that clears the operation.
        let confirmed = try snapshot(service)
        #expect(confirmed.operation == nil)
        #expect(confirmed.devices.first?.isConnected == true)
    }

    /// The deadline is already behind us by the time the state is read, so the
    /// only thing that keeps this from a timeout verdict is the rule that the
    /// real session list is read before the clock is consulted.
    @Test func aSessionThatConfirmsAfterTheDeadlineIsReportedAsConnectedNotAsATimeout() async throws {
        let clock = ManualClock()
        let bridge = StubSidecarBridge(devices: [Self.ipad], confirmationLag: 1)
        let service = makeService(bridge: bridge, clock: clock, connectTimeout: .milliseconds(1))
        _ = service.remoteConnect(deviceID: Self.ipad.identifier)
        try await drain(service)
        clock.advance(by: .seconds(1))
        let confirmed = try snapshot(service)
        #expect(confirmed.operation == nil)
        #expect(confirmed.devices.first?.isConnected == true)
    }

    @Test func aConnectThatNeverConfirmsTimesOutWithoutEverClaimingASession() async throws {
        let clock = ManualClock()
        let bridge = StubSidecarBridge(devices: [Self.ipad], confirmationLag: .max)
        let service = makeService(bridge: bridge, clock: clock)
        _ = service.remoteConnect(deviceID: Self.ipad.identifier)
        try await drain(service)
        // Inside the shipped window an unconfirmed session is still coming up,
        // not a failure the phone should explain.
        #expect(try snapshot(service).operation?.phase == .connecting)
        clock.advance(by: SidecarService.defaultConnectTimeout + .seconds(1))
        let failed = try snapshot(service)
        #expect(failed.operation?.phase == .failed)
        #expect(failed.operation?.errorCode == .commandTimeout)
        #expect(failed.devices.first?.isConnected == false)
        #expect(failed.connectedDevice == nil)
    }

    @Test func aDisconnectIsAcceptedWhileTheSessionIsStillUpAndClearsOnceTheSystemAgrees() async throws {
        let bridge = StubSidecarBridge(devices: [Self.ipad], connected: [Self.ipad.identifier])
        let service = makeService(bridge: bridge)
        guard case let .snapshot(accepted) = service.remoteDisconnect(deviceID: Self.ipad.identifier) else {
            Issue.record("the disconnect must be accepted")
            return
        }
        #expect(accepted.operation?.phase == .disconnecting)
        #expect(accepted.devices.first?.isConnected == true)
        try await drain(service)
        // The framework call and the system's own list agree, so the operation
        // is concluded before it is ever reported again.
        let confirmed = try snapshot(service)
        #expect(confirmed.operation == nil)
        #expect(confirmed.devices.first?.isConnected == false)
    }

    // MARK: - Switching targets

    @Test func switchingTargetsEndsTheCurrentSessionBeforeStartingTheNewOne() async throws {
        let bridge = StubSidecarBridge(
            devices: [Self.ipad, Self.studio],
            connected: [Self.studio.identifier],
            confirmationLag: .max
        )
        let service = makeService(bridge: bridge)
        guard case let .snapshot(accepted) = service.remoteConnect(deviceID: Self.ipad.identifier) else {
            Issue.record("a switch must be accepted")
            return
        }
        // The phone is told which device the operation is about, and that the
        // teardown it cannot time is part of the same operation.
        #expect(accepted.operation?.deviceID == Self.ipad.identifier)
        #expect(accepted.operation?.phase == .connecting)
        try await drain(service)
        #expect(bridge.disconnects == [Self.studio.identifier])
        #expect(bridge.connects == [Self.ipad.identifier])
    }

    /// A teardown that fails must leave the working session alone and must not
    /// quietly connect the second iPad on top of it.
    @Test func aSwitchWhoseTeardownFailsLeavesTheCurrentSessionRunning() async throws {
        let bridge = StubSidecarBridge(
            devices: [Self.ipad, Self.studio],
            connected: [Self.studio.identifier],
            confirmationLag: .max
        )
        bridge.disconnectError = .refused(domain: "SidecarErrorDomain", code: -1)
        let service = makeService(bridge: bridge)
        _ = service.remoteConnect(deviceID: Self.ipad.identifier)
        try await drain(service)
        #expect(bridge.connects.isEmpty)
        let failed = try snapshot(service)
        #expect(failed.operation?.phase == .failed)
        #expect(failed.operation?.errorCode == .sidecarConnectFailed)
        #expect(failed.connectedDevice?.id == Self.studio.identifier)
    }

    // MARK: - Failure codes

    @Test func theFrameworkErrorBecomesAStableCodeAndNeverASystemMessage() async throws {
        let unreachable = StubSidecarBridge(devices: [Self.ipad], confirmationLag: .max)
        unreachable.connectError = .refused(
            domain: "SidecarErrorDomain",
            code: SidecarService.deviceUnreachableErrorCode
        )
        let unreachableService = makeService(bridge: unreachable)
        _ = unreachableService.remoteConnect(deviceID: Self.ipad.identifier)

        let missing = StubSidecarBridge(devices: [Self.ipad], confirmationLag: .max)
        missing.connectError = .deviceMissing
        let missingService = makeService(bridge: missing)
        _ = missingService.remoteConnect(deviceID: Self.ipad.identifier)

        let gone = StubSidecarBridge(
            devices: [Self.ipad],
            connected: [Self.ipad.identifier],
            confirmationLag: .max
        )
        gone.disconnectError = .refused(domain: "SidecarErrorDomain", code: -1)
        let goneService = makeService(bridge: gone)
        _ = goneService.remoteDisconnect(deviceID: Self.ipad.identifier)

        try await drain(unreachableService, missingService, goneService)
        // The domain and code stay in the Mac's log; the phone gets a verdict it
        // can word, and -203 gets its own because the user can act on it.
        #expect(try snapshot(unreachableService).operation?.errorCode == .sidecarDeviceUnreachable)
        #expect(try snapshot(missingService).operation?.errorCode == .sidecarDeviceNotFound)
        #expect(try snapshot(goneService).operation?.errorCode == .sidecarDisconnectFailed)
    }

    // MARK: - Failures heal

    /// A verdict explains the last attempt; it is not a permanent state, and it
    /// must not lock the row the way a live operation does.
    @Test func aFailedAttemptDoesNotBlockTheNextOne() async throws {
        let clock = ManualClock()
        let bridge = StubSidecarBridge(devices: [Self.ipad, Self.studio], confirmationLag: .max)
        let service = makeService(bridge: bridge, clock: clock)
        _ = service.remoteConnect(deviceID: Self.ipad.identifier)
        try await drain(service)
        clock.advance(by: SidecarService.defaultConnectTimeout + .seconds(1))
        #expect(try snapshot(service).operation?.phase == .failed)
        guard case let .snapshot(accepted) = service.remoteConnect(deviceID: Self.studio.identifier) else {
            Issue.record("a failed attempt must not lock the service")
            return
        }
        #expect(accepted.operation?.deviceID == Self.studio.identifier)
        #expect(accepted.operation?.phase == .connecting)
    }

    @Test func aStaleFailureClearsOnceTheSystemContradictsIt() async throws {
        let clock = ManualClock()
        let bridge = StubSidecarBridge(devices: [Self.ipad], confirmationLag: .max)
        let service = makeService(bridge: bridge, clock: clock)
        _ = service.remoteConnect(deviceID: Self.ipad.identifier)
        try await drain(service)
        clock.advance(by: SidecarService.defaultConnectTimeout + .seconds(1))
        #expect(try snapshot(service).operation?.phase == .failed)
        // The user connected the same iPad from the Mac in the meantime.
        bridge.state = SidecarBridgeState(
            isSupported: true,
            devices: [Self.ipad],
            connectedIdentifiers: [Self.ipad.identifier]
        )
        let healed = try snapshot(service)
        #expect(healed.operation == nil)
        #expect(healed.connectedDevice?.id == Self.ipad.identifier)
    }

    @Test func aFailureThatTheSystemStillAgreesWithKeepsExplainingItself() async throws {
        let clock = ManualClock()
        let bridge = StubSidecarBridge(devices: [Self.ipad], confirmationLag: .max)
        let service = makeService(bridge: bridge, clock: clock)
        _ = service.remoteConnect(deviceID: Self.ipad.identifier)
        try await drain(service)
        clock.advance(by: SidecarService.defaultConnectTimeout + .seconds(1))
        #expect(try snapshot(service).operation?.phase == .failed)
        #expect(try snapshot(service).operation?.errorCode == .commandTimeout)
        // Healing needs the system to contradict the attempt. Nothing did, so
        // every later read still explains the same failure instead of dropping
        // it and leaving the phone with a row that says nothing.
        clock.advance(by: .seconds(600))
        #expect(try snapshot(service).operation?.phase == .failed)
        #expect(try snapshot(service).operation?.errorCode == .commandTimeout)
    }
}

/// The three Sidecar commands route through a stubbed host, so no test here
/// loads the private framework or touches a real display.
@Suite("Remote sidecar commands")
@MainActor
struct RemoteSidecarRouterTests {
    private final class StubSidecarHost: RemoteSidecarHosting {
        var isRemotelyAvailable: Bool
        var snapshot: RemoteSidecarSnapshot?
        var connectOutcome: RemoteSidecarOutcome
        var disconnectOutcome: RemoteSidecarOutcome
        private(set) var connects: [String] = []
        private(set) var disconnects: [String] = []

        init(
            isRemotelyAvailable: Bool = true,
            snapshot: RemoteSidecarSnapshot?,
            connectOutcome: RemoteSidecarOutcome,
            disconnectOutcome: RemoteSidecarOutcome
        ) {
            self.isRemotelyAvailable = isRemotelyAvailable
            self.snapshot = snapshot
            self.connectOutcome = connectOutcome
            self.disconnectOutcome = disconnectOutcome
        }

        func remoteSnapshot() -> RemoteSidecarSnapshot? { snapshot }

        func remoteConnect(deviceID: String) -> RemoteSidecarOutcome {
            connects.append(deviceID)
            return connectOutcome
        }

        func remoteDisconnect(deviceID: String) -> RemoteSidecarOutcome {
            disconnects.append(deviceID)
            return disconnectOutcome
        }
    }

    private static let sample = RemoteSidecarSnapshot(
        devices: [
            RemoteSidecarDevice(id: "ipad-1", name: "iPad", model: "iPad16,1", isConnected: false),
            RemoteSidecarDevice(id: "ipad-2", name: "Studio", model: nil, isConnected: true),
        ],
        operation: RemoteSidecarOperation(deviceID: "ipad-1", phase: .connecting)
    )

    private func makeRouter(sidecar: (any RemoteSidecarHosting)?) -> RemoteCommandRouter {
        RemoteCommandRouter(
            service: MacScreenControlService(
                credentials: ScreenCredentialStore(secretStore: InMemorySecretStore(), log: { _ in }),
                log: { _ in }
            ),
            sidecar: sidecar,
            log: { _ in }
        )
    }

    private func makeHost(
        snapshot: RemoteSidecarSnapshot? = Self.sample,
        connectOutcome: RemoteSidecarOutcome = .snapshot(Self.sample),
        disconnectOutcome: RemoteSidecarOutcome = .snapshot(Self.sample)
    ) -> StubSidecarHost {
        StubSidecarHost(
            snapshot: snapshot,
            connectOutcome: connectOutcome,
            disconnectOutcome: disconnectOutcome
        )
    }

    @Test func sidecarCommandsRefuseToRunWithoutAuthentication() async {
        for command in [RemoteCommand.getSidecarDevices, .connectSidecar, .disconnectSidecar] {
            let response = await makeRouter(sidecar: makeHost())
                .response(for: RemoteRequest(command: command, sequence: 1), isAuthenticated: false)
            #expect(!response.success, "\(command) must not run unauthenticated")
            #expect(response.error?.code == .unauthenticated)
        }
    }

    @Test func aMacWithoutSidecarAnswersUnsupportedCommand() async {
        // Both shapes: no host at all, and a host whose framework says this
        // machine cannot drive Sidecar.
        for host in [nil as (any RemoteSidecarHosting)?, makeHost(snapshot: nil)] {
            let response = await makeRouter(sidecar: host)
                .response(for: RemoteRequest(command: .getSidecarDevices, sequence: 1), isAuthenticated: true)
            #expect(!response.success)
            #expect(response.error?.code == .unsupportedCommand)
        }
    }

    @Test func getSidecarDevicesAnswersWithADecodableSnapshot() async throws {
        let response = await makeRouter(sidecar: makeHost())
            .response(for: RemoteRequest(command: .getSidecarDevices, sequence: 1), isAuthenticated: true)
        #expect(response.success)
        let snapshot = try #require(RemoteSidecarSnapshot.decoded(from: response.payload))
        #expect(snapshot == Self.sample)
        #expect(snapshot.connectedDevice?.id == "ipad-2")
        #expect(snapshot.operation?.phase == .connecting)
    }

    @Test func aTargetRequestWithoutAPayloadIsRefusedInsteadOfGuessed() async {
        let host = makeHost()
        for command in [RemoteCommand.connectSidecar, .disconnectSidecar] {
            let response = await makeRouter(sidecar: host)
                .response(for: RemoteRequest(command: command, sequence: 1), isAuthenticated: true)
            #expect(!response.success, "\(command) must not pick a device on its own")
            #expect(response.error?.code == .invalidMessage)
        }
        #expect(host.connects.isEmpty)
        #expect(host.disconnects.isEmpty)
    }

    @Test func aCorruptTargetPayloadIsRefused() async {
        let host = makeHost()
        let response = await makeRouter(sidecar: host).response(
            for: RemoteRequest(command: .connectSidecar, sequence: 1, payload: Data("not json".utf8)),
            isAuthenticated: true
        )
        #expect(!response.success)
        #expect(response.error?.code == .invalidMessage)
        #expect(host.connects.isEmpty)
    }

    @Test func connectAndDisconnectForwardTheDeviceIdentifierTheyWereGiven() async throws {
        let host = makeHost()
        let payload = try RemoteSidecarTargetRequest(deviceID: "ipad-1").encoded()
        let connect = await makeRouter(sidecar: host).response(
            for: RemoteRequest(command: .connectSidecar, sequence: 1, payload: payload),
            isAuthenticated: true
        )
        let disconnect = await makeRouter(sidecar: host).response(
            for: RemoteRequest(command: .disconnectSidecar, sequence: 2, payload: payload),
            isAuthenticated: true
        )
        #expect(host.connects == ["ipad-1"])
        #expect(host.disconnects == ["ipad-1"])
        #expect(connect.success)
        #expect(disconnect.success)
        // The reply is the picture the Mac reports now, which is how the phone
        // learns "accepted" without waiting for a session it cannot time.
        #expect(RemoteSidecarSnapshot.decoded(from: connect.payload)?.operation?.phase == .connecting)
    }

    @Test func aRefusedTargetCarriesTheMacsOwnStableCode() async throws {
        let host = makeHost(connectOutcome: .failure(.sidecarOperationInProgress))
        let payload = try RemoteSidecarTargetRequest(deviceID: "ipad-1").encoded()
        let response = await makeRouter(sidecar: host).response(
            for: RemoteRequest(command: .connectSidecar, sequence: 1, payload: payload),
            isAuthenticated: true
        )
        #expect(!response.success)
        #expect(response.error?.code == .sidecarOperationInProgress)
        #expect(response.payload == nil)
    }
}
