import Foundation
import Testing

@testable import MacPilotRemoteProtocol
@testable import MacPilotRemoteTransport

/// The challenge is a security boundary: the Mac learns a rotating BLE address
/// only when the phone proves it holds the pairing key. These tests pin the
/// encoding, the domain separation and the rejection paths.
@Suite("Remote BLE presence challenge")
struct RemoteBLEPresenceChallengeTests {
    @Test("HMAC-SHA256 matches the RFC 4231 vector")
    func hmacMatchesRFCVector() {
        // A plain SHA256(key || data) would also be deterministic and would
        // pass a self-consistency test, so pin a published vector instead.
        let tag = RemoteCrypto.hmacSHA256(
            key: Data("Jefe".utf8),
            data: Data("what do ya want for nothing?".utf8)
        )
        #expect(tag == Data(hex: "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"))
    }

    @Test("a challenge survives its binary encoding")
    func challengeRoundTrips() {
        let macID = UUID(uuidString: "64C01E3E-F335-12ED-3972-1D01D3A05A84")!
        let nonce = Data((0..<RemoteBLEPresenceChallenge.nonceLength).map { UInt8($0) })
        let challenge = RemoteBLEPresenceChallenge(macID: macID, nonce: nonce)
        let encoded = challenge.encoded
        #expect(encoded.count == RemoteBLEPresenceChallenge.encodedLength)
        #expect(encoded.first == RemoteBLEPresenceChallenge.version)
        let decoded = RemoteBLEPresenceChallenge(encoded: encoded)
        #expect(decoded == challenge)
        #expect(decoded?.macID == macID)
        #expect(decoded?.nonce == nonce)
    }

    @Test("the all-zero Mac identity survives the round trip")
    func zeroUUIDRoundTrips() {
        // A string or endian based converter would pass a random-UUID test and
        // still mangle this boundary value.
        let challenge = RemoteBLEPresenceChallenge(macID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
        #expect(RemoteBLEPresenceChallenge(encoded: challenge.encoded)?.macID == challenge.macID)
    }

    @Test("malformed challenges are rejected instead of guessed")
    func malformedChallengesAreRejected() {
        let challenge = RemoteBLEPresenceChallenge(macID: UUID())
        let encoded = challenge.encoded
        #expect(RemoteBLEPresenceChallenge(encoded: Data()) == nil)
        #expect(RemoteBLEPresenceChallenge(encoded: encoded.dropLast()) == nil)
        #expect(RemoteBLEPresenceChallenge(encoded: encoded + Data([0])) == nil)
        var wrongVersion = encoded
        wrongVersion[wrongVersion.startIndex] = RemoteBLEPresenceChallenge.version &+ 1
        #expect(RemoteBLEPresenceChallenge(encoded: wrongVersion) == nil)
    }

    @Test("only the pairing key for the addressed Mac verifies the response")
    func responseRequiresTheRightKey() {
        let key = RemoteCrypto.randomData(count: RemoteCrypto.pairingKeyLength)
        let otherKey = RemoteCrypto.randomData(count: RemoteCrypto.pairingKeyLength)
        let challenge = RemoteBLEPresenceChallenge(macID: UUID())
        let response = challenge.response(pairingKey: key)
        #expect(response.count == RemoteBLEPresenceChallenge.responseLength)
        #expect(challenge.isValidResponse(response, pairingKey: key))
        #expect(!challenge.isValidResponse(response, pairingKey: otherKey))
        #expect(!challenge.isValidResponse(Data(), pairingKey: key))
    }

    @Test("a response cannot be replayed under another nonce or Mac identity")
    func responsesAreBoundToNonceAndMac() {
        let key = RemoteCrypto.randomData(count: RemoteCrypto.pairingKeyLength)
        let macID = UUID()
        let nonce = Data(repeating: 7, count: RemoteBLEPresenceChallenge.nonceLength)
        let challenge = RemoteBLEPresenceChallenge(macID: macID, nonce: nonce)
        let response = challenge.response(pairingKey: key)
        let otherNonce = RemoteBLEPresenceChallenge(macID: macID, nonce: Data(repeating: 8, count: nonce.count))
        #expect(!otherNonce.isValidResponse(response, pairingKey: key))
        let otherMac = RemoteBLEPresenceChallenge(macID: UUID(), nonce: nonce)
        #expect(!otherMac.isValidResponse(response, pairingKey: key))
    }
}

private extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
