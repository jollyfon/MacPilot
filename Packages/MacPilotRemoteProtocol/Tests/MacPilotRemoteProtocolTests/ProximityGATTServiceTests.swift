import CoreBluetooth
import Foundation
import Testing

@testable import MacPilotRemoteTransport

/// The reversed-role service is a wire contract between a Mac running as a
/// peripheral and a phone running as a central. Both processes are updated
/// together, but a copy-paste between the two services would silently make one
/// side read a characteristic the other never answers.
@Suite("Proximity GATT contract")
struct ProximityGATTServiceTests {
    @Test("the service and characteristics are distinct from the existing BLE service")
    func uuidsDoNotCollide() {
        #expect(ProximityGATTService.serviceUUID == CBUUID(string: "6D616350-696C-6F74-0002-000000000001"))
        #expect(ProximityGATTService.macInfoCharacteristicUUID == CBUUID(string: "6D616350-696C-6F74-0002-000000000002"))
        #expect(ProximityGATTService.echoCharacteristicUUID == CBUUID(string: "6D616350-696C-6F74-0002-000000000003"))
        #expect(ProximityGATTService.responseCharacteristicUUID == CBUUID(string: "6D616350-696C-6F74-0002-000000000004"))

        #expect(Array(ProximityGATTService.serviceUUID.data.prefix(8)) == Array("macPilot".utf8))

        let all: Set<CBUUID> = [
            ProximityGATTService.serviceUUID,
            ProximityGATTService.macInfoCharacteristicUUID,
            ProximityGATTService.echoCharacteristicUUID,
            ProximityGATTService.responseCharacteristicUUID
        ]
        #expect(all.count == 4)

        let existing: Set<CBUUID> = [
            RemoteBLEService.serviceUUID,
            RemoteBLEService.psmCharacteristicUUID,
            RemoteBLEService.identityClaimCharacteristicUUID,
            RemoteBLEService.presenceChallengeCharacteristicUUID
        ]
        #expect(all.isDisjoint(with: existing))
    }

    @Test("Mac info fits an unnegotiated ATT read and round trips")
    func macInfoRoundTrips() {
        let id = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        let info = ProximityGATTMacInfo(deviceID: id)
        let encoded = info.encoded
        #expect(encoded.count == 17)
        // 20 bytes is the largest read payload on the default 23 byte ATT MTU.
        #expect(encoded.count <= 20)
        #expect(ProximityGATTMacInfo(encoded: encoded) == info)
    }

    @Test("a missing device identifier encodes as zeroes and decodes back to nil")
    func missingDeviceIDRoundTrips() {
        let encoded = ProximityGATTMacInfo(deviceID: nil).encoded
        #expect(encoded.count == 17)
        #expect(encoded.dropFirst().allSatisfy { $0 == 0 })
        #expect(ProximityGATTMacInfo(encoded: encoded)?.deviceID == nil)
    }

    @Test("an unknown version or wrong length is rejected")
    func macInfoRejectsGarbage() {
        var wrongVersion = ProximityGATTMacInfo(deviceID: UUID()).encoded
        wrongVersion[0] = 2
        #expect(ProximityGATTMacInfo(encoded: wrongVersion) == nil)
        #expect(ProximityGATTMacInfo(encoded: Data()) == nil)
        #expect(ProximityGATTMacInfo(encoded: Data(repeating: 1, count: 16)) == nil)
        #expect(ProximityGATTMacInfo(encoded: Data(repeating: 1, count: 18)) == nil)
    }

    @Test("an echo only matches the exact payload that was sent")
    func echoRequiresAnExactMatch() {
        let sent = ProximityGATTEcho.random()
        #expect(sent.count == ProximityGATTEcho.length)
        #expect(ProximityGATTEcho.isValid(sent, matching: sent))

        var tampered = sent
        tampered[tampered.startIndex] ^= 0xFF
        var longer = sent
        longer.append(0)
        #expect(!ProximityGATTEcho.isValid(tampered, matching: sent))
        #expect(!ProximityGATTEcho.isValid(Data(), matching: sent))
        #expect(!ProximityGATTEcho.isValid(Data(sent.prefix(15)), matching: sent))
        #expect(!ProximityGATTEcho.isValid(longer, matching: sent))
        #expect(!ProximityGATTEcho.isValid(sent, matching: Data(sent.prefix(15))))
    }
}
