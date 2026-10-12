import Foundation
import Testing
@testable import MacPilotRemoteProtocol

/// Wire contract for the Sidecar commands. The invariants that matter are the
/// ones an older peer depends on: the three commands are authenticated, the
/// capability is never implied by another feature, and a phone that does not
/// declare `sidecar` still decodes the hello with the published vocabulary.
struct RemoteSidecarProtocolTests {
    private static let sampleDevices = [
        RemoteSidecarDevice(id: "11111111-1111-1111-1111-111111111111", name: "iPad", model: "iPad16,1", isConnected: false),
        RemoteSidecarDevice(id: "22222222-2222-2222-2222-222222222222", name: "iPad", model: "iPad14,3", isConnected: true),
    ]

    @Test func sidecarCommandsAlwaysRequireAuthentication() {
        for command in [RemoteCommand.getSidecarDevices, .connectSidecar, .disconnectSidecar] {
            #expect(command.requiresAuthentication)
        }
    }

    @Test func sidecarIsNegotiatedOnlyFromAnExplicitClientDeclaration() {
        let advertised: [RemoteCapability] = [.remoteDesktop, .navigationKeys, .sidecar]
        #expect(!RemoteCapability.negotiated(advertised, features: nil).contains(.sidecar))
        #expect(!RemoteCapability.negotiated(advertised, features: []).contains(.sidecar))
        #expect(!RemoteCapability.negotiated(advertised, features: ["remoteDesktop"]).contains(.sidecar))
        #expect(RemoteCapability.negotiated(advertised, features: ["sidecar"]) == [.sidecar])
    }

    /// The published 1.0/1.1 phone decodes capabilities as a closed four-case
    /// enum, so `sidecar` must never appear in a hello it receives: a client
    /// that does not declare the feature is exactly such a phone.
    @Test func aClientThatDoesNotDeclareSidecarNeverSeesItAdvertised() throws {
        for features: [String]? in [nil, [], ["remoteDesktop"], ["navigationKeys"], ["futureUnknownFeature"]] {
            let hello = RemoteHandshakeMessage(
                kind: .serverHello,
                capabilities: RemoteCapability.negotiated(RemoteCapability.allCases, features: features)
            )
            #expect(hello.capabilities?.contains(.sidecar) == false)
            var wire = try RemoteFrameCodec.encodePlain(hello)
            let body = try #require(RemoteFrameCodec.extractFrames(from: &wire).first)
            let decoded = try JSONDecoder().decode(RemoteHandshakeMessage.self, from: Data(body.dropFirst()))
            #expect(decoded.capabilities?.contains(.sidecar) == false)
        }
    }

    @Test func aSnapshotSurvivesThePayloadRoundTrip() throws {
        let snapshot = RemoteSidecarSnapshot(
            devices: Self.sampleDevices,
            operation: RemoteSidecarOperation(deviceID: Self.sampleDevices[0].id, phase: .connecting)
        )
        let decoded = try #require(RemoteSidecarSnapshot.decoded(from: snapshot.encoded()))
        #expect(decoded == snapshot)
        #expect(decoded.connectedDevice?.id == Self.sampleDevices[1].id)
        #expect(decoded.operation?.errorCode == nil)
    }

    @Test func aFailureCarriesItsStableErrorCodeAndNothingElse() throws {
        let snapshot = RemoteSidecarSnapshot(
            devices: [],
            operation: RemoteSidecarOperation(
                deviceID: "gone",
                phase: .failed,
                errorCode: .sidecarDeviceUnreachable
            )
        )
        let decoded = try #require(RemoteSidecarSnapshot.decoded(from: snapshot.encoded()))
        #expect(decoded.operation?.errorCode == .sidecarDeviceUnreachable)
        #expect(decoded.connectedDevice == nil)
    }

    @Test func aTargetRequestRefusesToGuessAMissingOrCorruptDevice() {
        #expect(RemoteSidecarTargetRequest.decoded(from: nil) == nil)
        #expect(RemoteSidecarTargetRequest.decoded(from: Data()) == nil)
        #expect(RemoteSidecarTargetRequest.decoded(from: Data("not json".utf8)) == nil)
        #expect(RemoteSidecarSnapshot.decoded(from: Data("not json".utf8)) == nil)
    }

    @Test func aTargetRequestRoundTripsItsDeviceIdentifier() throws {
        let request = RemoteSidecarTargetRequest(deviceID: Self.sampleDevices[1].id)
        let decoded = try #require(RemoteSidecarTargetRequest.decoded(from: request.encoded()))
        #expect(decoded == request)
    }

    @Test func everySidecarErrorCodeHasItsOwnWireSpelling() {
        let codes: [RemoteErrorCode] = [
            .sidecarUnavailable,
            .sidecarDeviceNotFound,
            .sidecarAlreadyConnected,
            .sidecarOperationInProgress,
            .sidecarDeviceUnreachable,
            .sidecarConnectFailed,
            .sidecarDisconnectFailed,
        ]
        #expect(Set(codes.map(\.rawValue)).count == codes.count)
        #expect(codes.allSatisfy { RemoteErrorCode(rawValue: $0.rawValue) == $0 })
    }
}
