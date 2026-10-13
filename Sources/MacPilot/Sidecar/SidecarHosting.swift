import Foundation
import MacPilotRemoteProtocol

/// The Sidecar surface the remote server may reach. A protocol rather than
/// `SidecarService` itself, so the router is testable with a stub and the remote
/// channel never has to know that a private framework is involved.
@MainActor
protocol RemoteSidecarHosting: AnyObject {
    /// False on a Mac whose SidecarCore reports it cannot drive Sidecar right
    /// now. The `sidecar` capability does not depend on this: the bit says the
    /// commands are answered, and a Mac that cannot obey says so per request with
    /// `sidecarUnavailable`, so the phone always gets a sentence rather than
    /// silence.
    var isRemotelyAvailable: Bool { get }

    /// `nil` when this Mac cannot drive Sidecar — the router answers
    /// `sidecarUnavailable`, which is this Mac's own verdict rather than the
    /// message an older Mac that has no Sidecar code at all would send.
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
