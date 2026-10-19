import Foundation
import Testing
@testable import PilotNest

@Suite("BLE advertising policy")
@MainActor
struct RemoteBLEAdvertisingPolicyTests {
    @Test func proximityBindingKeepsAdvertisingAfterTheAppIsBackgrounded() {
        #expect(RemoteBLEAdvertisingPolicy.shouldAdvertise(
            isForeground: false,
            wantsProximity: true,
            isIdentityProbeActive: false,
            hasManualTarget: false,
            bluetoothIsNeededForRace: false,
            keepsActiveBLESession: false
        ))
    }

    @Test func backgroundAdvertisingStopsWithoutAProximityBinding() {
        #expect(!RemoteBLEAdvertisingPolicy.shouldAdvertise(
            isForeground: false,
            wantsProximity: false,
            isIdentityProbeActive: false,
            hasManualTarget: false,
            bluetoothIsNeededForRace: true,
            keepsActiveBLESession: false
        ))
        #expect(!RemoteBLEAdvertisingPolicy.shouldAdvertise(
            isForeground: false,
            wantsProximity: false,
            isIdentityProbeActive: true,
            hasManualTarget: false,
            bluetoothIsNeededForRace: false,
            keepsActiveBLESession: false
        ))
    }

    @Test func foregroundKeepsTheControlRaceAndIdentityProbeAdvertising() {
        #expect(RemoteBLEAdvertisingPolicy.shouldAdvertise(
            isForeground: true,
            wantsProximity: false,
            isIdentityProbeActive: false,
            hasManualTarget: false,
            bluetoothIsNeededForRace: true,
            keepsActiveBLESession: false
        ))
        #expect(RemoteBLEAdvertisingPolicy.shouldAdvertise(
            isForeground: true,
            wantsProximity: false,
            isIdentityProbeActive: true,
            hasManualTarget: false,
            bluetoothIsNeededForRace: false,
            keepsActiveBLESession: false
        ))
    }

    @Test func manualTargetAndIdleBackgroundStayOffTheAir() {
        #expect(!RemoteBLEAdvertisingPolicy.shouldAdvertise(
            isForeground: true,
            wantsProximity: true,
            isIdentityProbeActive: false,
            hasManualTarget: true,
            bluetoothIsNeededForRace: true,
            keepsActiveBLESession: false
        ))
        #expect(!RemoteBLEAdvertisingPolicy.shouldAdvertise(
            isForeground: true,
            wantsProximity: false,
            isIdentityProbeActive: false,
            hasManualTarget: false,
            bluetoothIsNeededForRace: false,
            keepsActiveBLESession: false
        ))
    }

    @Test func anActiveBLESessionOutlivesEveryOtherReasonToStop() {
        #expect(RemoteBLEAdvertisingPolicy.shouldAdvertise(
            isForeground: false,
            wantsProximity: false,
            isIdentityProbeActive: false,
            hasManualTarget: true,
            bluetoothIsNeededForRace: false,
            keepsActiveBLESession: true
        ))
    }

    @Test func theProximityFlagPersistsAndOldRecordsStillDecode() throws {
        let suiteName = "RemoteBLEAdvertisingPolicyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PairedMacStore(defaults: defaults)
        let macID = UUID()
        store.ensurePaired(id: macID, name: "Mac")
        #expect(store.mac(id: macID)?.wantsBLEProximity == nil)

        store.setWantsBLEProximity(true, id: macID)
        #expect(store.mac(id: macID)?.wantsBLEProximity == true)

        let reloaded = PairedMacStore(defaults: defaults)
        #expect(reloaded.mac(id: macID)?.wantsBLEProximity == true)

        // Records written before the field existed must keep decoding.
        let legacy = #"[{"id":"\#(UUID().uuidString)","name":"Old"}]"#
        defaults.set(Data(legacy.utf8), forKey: "MacPilotRemote.pairedMacs")
        let legacyStore = PairedMacStore(defaults: defaults)
        #expect(legacyStore.pairedMacs.count == 1)
        #expect(legacyStore.pairedMacs.first?.wantsBLEProximity == nil)
    }
}
