import Foundation
import MacPilotRemoteProtocol

/// The Sidecar surface the remote server may reach. A protocol rather than
/// `SidecarService` itself, so the router is testable with a stub and the remote
/// channel never has to know that a private framework is involved.
@MainActor
protocol RemoteSidecarHosting: AnyObject {
    /// False on a Mac whose SidecarCore reports it cannot drive Sidecar. The
    /// server withholds the `sidecar` capability in that case, so the phone
    /// hides the entry instead of offering a control that cannot work.
    var isRemotelyAvailable: Bool { get }

    /// `nil` when this Mac cannot drive Sidecar — the router answers
    /// `unsupportedCommand`, which is exactly how an older Mac reads to a phone
    /// that never saw the capability.
    func remoteSnapshot() -> RemoteSidecarSnapshot?

    /// Accepted immediately: the returned snapshot carries the operation phase,
    /// and the outcome arrives on a later poll. Starting a session outlasts any
    /// RPC timeout the phone can reasonably wait through.
    func remoteConnect(deviceID: String) -> RemoteSidecarOutcome

    func remoteDisconnect(deviceID: String) -> RemoteSidecarOutcome
}

enum RemoteSidecarOutcome: Equatable {
    /// The current picture after the request was handled. A refusal that still
    /// wants to show the device list (already connected, nothing in flight)
    /// comes back this way with the reason in `operation`.
    case snapshot(RemoteSidecarSnapshot)
    /// Refused before anything was attempted. The phone maps the code to its own
    /// wording; no raw system error ever crosses the network.
    case failure(RemoteErrorCode)
}
