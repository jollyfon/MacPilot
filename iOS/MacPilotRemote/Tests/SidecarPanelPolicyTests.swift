import Foundation
import MacPilotRemoteProtocol
import Testing
@testable import PilotNest

struct SidecarPanelPolicyTests {
    private let free = RemoteSidecarDevice(id: "free", name: "iPad", model: "iPad16,1", isConnected: false)
    private let mirroring = RemoteSidecarDevice(id: "busy", name: "Studio", model: nil, isConnected: true)

    private func snapshot(
        devices: [RemoteSidecarDevice],
        operation: RemoteSidecarOperation? = nil
    ) -> RemoteSidecarSnapshot {
        RemoteSidecarSnapshot(devices: devices, operation: operation)
    }

    // MARK: - Polling

    @Test func aClosedPanelOrADeadLinkNeverPolls() {
        #expect(SidecarPanelPolicy.pollInterval(
            isPanelVisible: false, isConnected: true, hasOperation: true) == nil)
        #expect(SidecarPanelPolicy.pollInterval(
            isPanelVisible: true, isConnected: false, hasOperation: true) == nil)
        #expect(SidecarPanelPolicy.pollInterval(
            isPanelVisible: false, isConnected: false, hasOperation: false) == nil)
    }

    @Test func anOperationEarnsTheFastCadenceAndASettledListDoesNot() {
        #expect(SidecarPanelPolicy.pollInterval(
            isPanelVisible: true, isConnected: true, hasOperation: true) == .seconds(1))
        #expect(SidecarPanelPolicy.pollInterval(
            isPanelVisible: true, isConnected: true, hasOperation: false) == .seconds(3))
    }

    // MARK: - Panel state

    @Test func aMissingLinkOutranksEveryListState() {
        #expect(SidecarPanelPolicy.panelState(
            isConnected: false, snapshot: snapshot(devices: [free]), didFailToLoad: true) == .macDisconnected)
        #expect(SidecarPanelPolicy.panelState(
            isConnected: false, snapshot: nil, didFailToLoad: false) == .macDisconnected)
    }

    /// "No iPad found" and "cannot look" are different facts. Reporting the
    /// second as the first is what makes a working feature look broken.
    @Test func cannotSearchIsNeverReportedAsFoundNothing() {
        #expect(SidecarPanelPolicy.panelState(
            isConnected: true, snapshot: nil, didFailToLoad: false) == .loading)
        #expect(SidecarPanelPolicy.panelState(
            isConnected: true, snapshot: nil, didFailToLoad: true) == .unreachable)
        #expect(SidecarPanelPolicy.panelState(
            isConnected: true, snapshot: snapshot(devices: []), didFailToLoad: false) == .empty)
        #expect(SidecarPanelPolicy.panelState(
            isConnected: true, snapshot: snapshot(devices: [free]), didFailToLoad: false) == .ready)
    }

    @Test func aFailedRefreshKeepsTheLastKnownListInsteadOfBlankingIt() {
        #expect(SidecarPanelPolicy.panelState(
            isConnected: true, snapshot: snapshot(devices: [free]), didFailToLoad: true) == .ready)
    }

    // MARK: - Row status

    @Test func anOperationOutranksWhatTheSystemListSays() {
        // The connected list lags a session that is still coming up, so a row
        // must not claim success the Mac has not confirmed.
        #expect(SidecarPanelPolicy.rowStatus(
            device: mirroring,
            operation: RemoteSidecarOperation(deviceID: mirroring.id, phase: .connecting)) == .connecting)
        #expect(SidecarPanelPolicy.rowStatus(
            device: mirroring,
            operation: RemoteSidecarOperation(deviceID: mirroring.id, phase: .disconnecting)) == .disconnecting)
        #expect(SidecarPanelPolicy.rowStatus(
            device: mirroring,
            operation: RemoteSidecarOperation(
                deviceID: mirroring.id, phase: .failed, errorCode: .sidecarDeviceUnreachable))
            == .failed("errorSidecarDeviceUnreachable"))
    }

    @Test func aFailureWithoutACodeStillSaysItFailed() {
        #expect(SidecarPanelPolicy.rowStatus(
            device: free,
            operation: RemoteSidecarOperation(deviceID: free.id, phase: .failed, errorCode: nil))
            == .failed("sidecarFailed"))
    }

    @Test func anOperationOnAnotherIPadLeavesThisRowAlone() {
        #expect(SidecarPanelPolicy.rowStatus(
            device: free,
            operation: RemoteSidecarOperation(deviceID: mirroring.id, phase: .connecting)) == .idle)
        #expect(SidecarPanelPolicy.rowStatus(device: mirroring, operation: nil) == .connected)
        #expect(SidecarPanelPolicy.rowStatus(device: free, operation: nil) == .idle)
        #expect(SidecarPanelPolicy.RowStatus.connected.statusKey == "sidecarConnected")
        #expect(SidecarPanelPolicy.RowStatus.idle.statusKey == nil)
        #expect(SidecarPanelPolicy.RowStatus.connecting.isBusy)
        #expect(!SidecarPanelPolicy.RowStatus.failed("errorTimeout").isBusy)
    }

    // MARK: - Sending

    /// A failure stays in the snapshot to explain the last attempt, and the Mac
    /// accepts a new request over it. Blocking here would strand the row until
    /// the session state happened to heal the verdict.
    @Test func aFailedAttemptDoesNotLockTheRowButALiveOneDoes() {
        #expect(SidecarPanelPolicy.canSendTargetRequest(
            snapshot: snapshot(devices: [free], operation: RemoteSidecarOperation(
                deviceID: free.id, phase: .failed, errorCode: .sidecarConnectFailed)),
            isRequestInFlight: false))
        #expect(!SidecarPanelPolicy.canSendTargetRequest(
            snapshot: snapshot(devices: [free], operation: RemoteSidecarOperation(
                deviceID: free.id, phase: .connecting)),
            isRequestInFlight: false))
        #expect(!SidecarPanelPolicy.canSendTargetRequest(
            snapshot: snapshot(devices: [mirroring], operation: RemoteSidecarOperation(
                deviceID: mirroring.id, phase: .disconnecting)),
            isRequestInFlight: false))
        #expect(SidecarPanelPolicy.canSendTargetRequest(
            snapshot: snapshot(devices: [free]), isRequestInFlight: false))
        #expect(SidecarPanelPolicy.canSendTargetRequest(snapshot: nil, isRequestInFlight: false))
    }

    @Test func aRequestStillOnTheWireBlocksEveryRowIncludingOneWithNoOperation() {
        #expect(!SidecarPanelPolicy.canSendTargetRequest(
            snapshot: snapshot(devices: [free]), isRequestInFlight: true))
        #expect(!SidecarPanelPolicy.canSendTargetRequest(snapshot: nil, isRequestInFlight: true))
    }

    // MARK: - Switching

    @Test func onlyATargetSwitchNeedsConfirming() {
        #expect(!SidecarPanelPolicy.requiresSwitchConfirmation(snapshot: nil, targetID: free.id))
        #expect(!SidecarPanelPolicy.requiresSwitchConfirmation(
            snapshot: snapshot(devices: [free]), targetID: free.id))
        #expect(!SidecarPanelPolicy.requiresSwitchConfirmation(
            snapshot: snapshot(devices: [mirroring, free]), targetID: mirroring.id))
        // Sidecar drives one iPad at a time, so this tap ends a live session.
        #expect(SidecarPanelPolicy.requiresSwitchConfirmation(
            snapshot: snapshot(devices: [mirroring, free]), targetID: free.id))
    }
}
