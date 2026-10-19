import Foundation
import Testing
@testable import MacPilotRemoteProtocol

/// Wire contract for the BLE identity claim. The claim exists because learning
/// a phone's peripheral UUID over an encrypted L2CAP channel fails on real
/// hardware; everything here protects the replacement path without widening
/// what an old peer can receive.
struct RemoteBLEIdentityClaimTests {
    @Test func claimingIdentityAlwaysRequiresAuthentication() {
        #expect(RemoteCommand.claimBLEIdentity.requiresAuthentication)
    }

    @Test func aClaimIsNegotiatedOnlyFromAnExplicitClientDeclaration() {
        let advertised: [RemoteCapability] = [.remoteDesktop, .bleIdentityLearning, .bleIdentityClaim]
        #expect(!RemoteCapability.negotiated(advertised, features: nil).contains(.bleIdentityClaim))
        #expect(!RemoteCapability.negotiated(advertised, features: ["bleIdentityLearning"]).contains(.bleIdentityClaim))
        #expect(
            RemoteCapability.negotiated(advertised, features: ["bleIdentityClaim"])
                == [.bleIdentityClaim]
        )
    }

    /// Published phone builds decode capabilities as a closed enum. A phone that
    /// does not declare the feature is exactly such a build, so it must never
    /// see the new case in a server hello.
    @Test func aClientThatDoesNotDeclareTheClaimNeverSeesIt() throws {
        for features: [String]? in [nil, [], ["bleIdentityLearning"], ["remoteDesktop"]] {
            let hello = RemoteHandshakeMessage(
                kind: .serverHello,
                capabilities: RemoteCapability.negotiated(RemoteCapability.allCases, features: features)
            )
            #expect(hello.capabilities?.contains(.bleIdentityClaim) == false)
            var wire = try RemoteFrameCodec.encodePlain(hello)
            let body = try #require(RemoteFrameCodec.extractFrames(from: &wire).first)
            let decoded = try JSONDecoder().decode(RemoteHandshakeMessage.self, from: Data(body.dropFirst()))
            #expect(decoded.capabilities?.contains(.bleIdentityClaim) == false)
        }
    }

    @Test func aClaimSurvivesThePayloadRoundTrip() throws {
        let token = RemoteCrypto.randomData(count: RemoteBLEIdentityClaim.tokenLength)
        let claim = RemoteBLEIdentityClaim(token: token, validity: 30)
        let decoded = try #require(RemoteBLEIdentityClaim.decoded(from: claim.encoded()))
        #expect(decoded == claim)
    }

    @Test func aWrongSizedTokenIsRefusedInsteadOfTrimmed() {
        for count in [0, 1, RemoteBLEIdentityClaim.tokenLength - 1, RemoteBLEIdentityClaim.tokenLength + 1, 32] {
            let claim = RemoteBLEIdentityClaim(token: RemoteCrypto.randomData(count: count), validity: 30)
            #expect(!claim.isValid)
            #expect(RemoteBLEIdentityClaim.decoded(from: try? claim.encoded()) == nil)
        }
    }

    @Test func aClaimCannotLiveLongerThanItsWindow() {
        let token = RemoteCrypto.randomData(count: RemoteBLEIdentityClaim.tokenLength)
        for validity: TimeInterval in [0, -1, RemoteBLEIdentityClaim.maximumValidity + 1] {
            let claim = RemoteBLEIdentityClaim(token: token, validity: validity)
            #expect(!claim.isValid)
            #expect(RemoteBLEIdentityClaim.decoded(from: try? claim.encoded()) == nil)
        }
        let bounded = RemoteBLEIdentityClaim(token: token, validity: RemoteBLEIdentityClaim.maximumValidity)
        #expect(bounded.isValid)
    }

    @Test func aMissingOrCorruptPayloadDecodesToNothing() {
        #expect(RemoteBLEIdentityClaim.decoded(from: nil) == nil)
        #expect(RemoteBLEIdentityClaim.decoded(from: Data()) == nil)
        #expect(RemoteBLEIdentityClaim.decoded(from: Data("not json".utf8)) == nil)
        let token = RemoteCrypto.randomData(count: RemoteBLEIdentityClaim.tokenLength)
        #expect(RemoteBLEIdentityClaim.decoded(from: try? JSONEncoder().encode(["token": token])) == nil)
    }
}
