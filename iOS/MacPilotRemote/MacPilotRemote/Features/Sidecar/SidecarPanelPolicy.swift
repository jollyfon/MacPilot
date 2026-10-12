import Foundation
import MacPilotRemoteProtocol

/// What the Sidecar sheet shows and when it asks the Mac again.
///
/// Pure on purpose. Every rule here is about not lying to the user, and a rule
/// that only holds while a real Mac answers cannot be tested at all.
enum SidecarPanelPolicy {
    /// Why the list looks the way it does. "No iPad found" and "cannot look"
    /// are different facts and must never share one empty screen.
    enum PanelState: Equatable {
        /// No authenticated link, so there is nobody to ask.
        case macDisconnected
        /// The first answer has not arrived yet.
        case loading
        /// The Mac refused or the request was lost.
        case unreachable
        /// The Mac answered and saw no iPad it could use.
        case empty
        case ready
    }

    /// What one row is doing, which decides both its text and whether it takes
    /// a tap.
    enum RowStatus: Equatable {
        /// Reachable and idle: the row offers a connect.
        case idle
        /// The system reports a live session: the row offers a disconnect.
        case connected
        case connecting
        case disconnecting
        /// Carries the message key of the stable code the Mac sent.
        case failed(String)

        /// `nil` while the row shows an action instead of a status.
        var statusKey: String? {
            switch self {
            case .idle: return nil
            case .connected: return "sidecarConnected"
            case .connecting: return "sidecarConnecting"
            case .disconnecting: return "sidecarDisconnecting"
            case .failed(let key): return key
            }
        }

        var isBusy: Bool { self == .connecting || self == .disconnecting }
    }

    static func panelState(
        isConnected: Bool,
        snapshot: RemoteSidecarSnapshot?,
        didFailToLoad: Bool
    ) -> PanelState {
        guard isConnected else { return .macDisconnected }
        guard let snapshot else { return didFailToLoad ? .unreachable : .loading }
        return snapshot.devices.isEmpty ? .empty : .ready
    }

    /// An operation outranks the connected flag: the system's list lags a
    /// session that is still coming up, and reporting "connected" before the
    /// Mac confirms it is exactly the lie this feature must not tell.
    static func rowStatus(device: RemoteSidecarDevice, operation: RemoteSidecarOperation?) -> RowStatus {
        if let operation, operation.deviceID == device.id {
            switch operation.phase {
            case .connecting: return .connecting
            case .disconnecting: return .disconnecting
            case .failed: return .failed(operation.errorCode?.messageKey ?? "sidecarFailed")
            }
        }
        return device.isConnected ? .connected : .idle
    }

    /// Whether a row may accept a tap right now.
    ///
    /// A failure stays in the snapshot to explain the last attempt, and the Mac
    /// accepts a new request over it — so only a live operation blocks. Blocking
    /// on a failure would strand the row until the session state happened to
    /// heal it.
    static func canSendTargetRequest(snapshot: RemoteSidecarSnapshot?, isRequestInFlight: Bool) -> Bool {
        guard !isRequestInFlight else { return false }
        guard let phase = snapshot?.operation?.phase else { return true }
        return phase == .failed
    }

    /// Whether tapping `targetID` tears down another iPad's session first.
    static func requiresSwitchConfirmation(snapshot: RemoteSidecarSnapshot?, targetID: String) -> Bool {
        guard let connected = snapshot?.connectedDevice else { return false }
        return connected.id != targetID
    }

    /// How long to wait before asking the Mac again, or `nil` to stop asking.
    ///
    /// A closed sheet polls nothing. The Mac answers from `SidecarCore`, which
    /// is not free, and no result is worth fetching for a list nobody sees.
    static func pollInterval(isPanelVisible: Bool, isConnected: Bool, hasOperation: Bool) -> Duration? {
        guard isPanelVisible, isConnected else { return nil }
        // Only an operation changes on its own, so only it earns the fast
        // cadence; a settled list changes when an iPad appears or leaves.
        return hasOperation ? .seconds(1) : .seconds(3)
    }
}
