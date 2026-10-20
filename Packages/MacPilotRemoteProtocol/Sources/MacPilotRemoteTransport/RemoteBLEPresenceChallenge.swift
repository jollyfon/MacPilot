import Foundation
import MacPilotRemoteProtocol

/// Lets a paired Mac prove that a newly seen BLE peripheral is its phone.
///
/// iOS rotates the advertised BLE address every few minutes, and the Mac sees
/// each address as a new `CBPeripheral.identifier`. The foreground identity
/// claim cannot cover that: it needs an authenticated network session and the
/// phone app in the foreground, while the rotation happens with the app asleep
/// in a pocket. This challenge runs entirely over GATT, which the phone's
/// `bluetooth-peripheral` background mode keeps answering.
///
/// Authentication proves *identity*, never proximity: the caller still requires
/// ordinary RSSI samples before the learned address may unlock anything.
public struct RemoteBLEPresenceChallenge: Equatable, Sendable {
    public static let version: UInt8 = 1
    public static let nonceLength = 16
    public static let responseLength = 32
    public static let encodedLength = 1 + nonceLength + 16

    /// Domain separation: this tag can never be confused with a pairing proof
    /// or a session key even if the same long-term key is used.
    private static let label = Data("MacPilotRemote-v1-ble-presence".utf8)

    public let macID: UUID
    public let nonce: Data

    public init(macID: UUID, nonce: Data = RemoteCrypto.randomData(count: nonceLength)) {
        self.macID = macID
        self.nonce = nonce
    }

    /// Strict decode: an unrecognised version or an unexpected length is
    /// rejected rather than interpreted with guessed field offsets.
    public init?(encoded data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count == Self.encodedLength, bytes[0] == Self.version else { return nil }
        let nonceEnd = 1 + Self.nonceLength
        let idBytes = Array(bytes[nonceEnd..<Self.encodedLength])
        self.macID = UUID(uuid: (
            idBytes[0], idBytes[1], idBytes[2], idBytes[3],
            idBytes[4], idBytes[5], idBytes[6], idBytes[7],
            idBytes[8], idBytes[9], idBytes[10], idBytes[11],
            idBytes[12], idBytes[13], idBytes[14], idBytes[15]
        ))
        self.nonce = Data(bytes[1..<nonceEnd])
    }

    public var encoded: Data {
        var data = Data([Self.version])
        data.append(nonce)
        data.append(Self.bytes(of: macID))
        return data
    }

    /// The phone computes this with the Mac's pairing key. Only the two paired
    /// devices can produce or verify it.
    public func response(pairingKey: Data) -> Data {
        RemoteCrypto.hmacSHA256(key: pairingKey, data: Self.message(macID: macID, nonce: nonce))
    }

    public func isValidResponse(_ response: Data, pairingKey: Data) -> Bool {
        RemoteCrypto.constantTimeEquals(response, self.response(pairingKey: pairingKey))
    }

    private static func message(macID: UUID, nonce: Data) -> Data {
        var data = label
        data.append(bytes(of: macID))
        data.append(nonce)
        return data
    }

    private static func bytes(of uuid: UUID) -> Data {
        withUnsafeBytes(of: uuid.uuid) { Data($0) }
    }
}
