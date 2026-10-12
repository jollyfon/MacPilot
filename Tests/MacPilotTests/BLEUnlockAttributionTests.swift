import Foundation
import Testing
@testable import MacPilot

@MainActor
struct BLEUnlockAttributionTests {
    @Test func externalUnlockObservedBeforeTheNotificationCompletesItsHistory() throws {
        var scripts: [String] = []
        let model = BLEUnlockModel(eventScriptRunner: { scripts.append($0) })
        defer { model.shutdown() }
        model.screenLockStateProbe = { .unlocked }
        let recorded = model.settings.screenLockHistory.recordLock(at: Date().addingTimeInterval(-30), source: .automatic)
        #expect(recorded)

        model.confirmAutomaticUnlock(source: "screenState deadline=2.0")

        let entry = try #require(model.screenLockHistory.first)
        #expect(!entry.isStillLocked)
        #expect(entry.unlockSource == .manual)
        #expect(scripts == ["intruded"])
        model.confirmAutomaticUnlock(source: "screenIsUnlockedNotification")
        #expect(scripts == ["intruded"], "The delayed notification must not duplicate completion effects")
    }

    @Test func anAlreadyUnlockedDesktopWithoutARequestCannotCreateUnlockEffects() {
        var scripts: [String] = []
        let model = BLEUnlockModel(eventScriptRunner: { scripts.append($0) })
        defer { model.shutdown() }
        model.screenLockStateProbe = { .unlocked }

        model.confirmAutomaticUnlock(source: "screenState deadline=2.0")

        #expect(model.screenLockHistory.isEmpty)
        #expect(scripts.isEmpty, "Reading an already unlocked session is not a new automatic unlock")
    }

    @Test func aRealPendingAutomaticRequestKeepsItsAutomaticAttribution() throws {
        var scripts: [String] = []
        let model = BLEUnlockModel(eventScriptRunner: { scripts.append($0) })
        defer { model.shutdown() }
        model.screenLockStateProbe = { .unlocked }
        let recorded = model.settings.screenLockHistory.recordLock(at: Date().addingTimeInterval(-30), source: .automatic)
        #expect(recorded)
        // Attribute a mocked command; do not fetch credentials or post keys.
        model.noteAutomaticUnlockRequest(at: Date().timeIntervalSince1970)

        model.confirmAutomaticUnlock(source: "screenIsUnlockedNotification")

        let entry = try #require(model.screenLockHistory.first)
        #expect(entry.unlockSource == .automatic)
        #expect(!entry.isStillLocked)
        #expect(scripts == ["unlocked"])
    }

    @Test func anExpiredAutomaticRequestCannotClaimALaterExternalUnlock() throws {
        var scripts: [String] = []
        let model = BLEUnlockModel(eventScriptRunner: { scripts.append($0) })
        defer { model.shutdown() }
        model.screenLockStateProbe = { .unlocked }
        let recorded = model.settings.screenLockHistory.recordLock(at: Date().addingTimeInterval(-60), source: .automatic)
        #expect(recorded)
        model.noteAutomaticUnlockRequest(at: Date().timeIntervalSince1970 - 30)

        model.confirmAutomaticUnlock(source: "screenState deadline=2.0")

        let entry = try #require(model.screenLockHistory.first)
        #expect(entry.unlockSource == .manual)
        #expect(scripts == ["intruded"])
    }

    @Test func lockedOrUnknownStateCannotCompleteHistoryOrRunUnlockEffects() throws {
        for state in [BLEScreenLockState.locked, .unknown] {
            var scripts: [String] = []
            let model = BLEUnlockModel(eventScriptRunner: { scripts.append($0) })
            defer { model.shutdown() }
            model.screenLockStateProbe = { state }
            let recorded = model.settings.screenLockHistory.recordLock(at: Date().addingTimeInterval(-30), source: .automatic)
            #expect(recorded)
            model.noteAutomaticUnlockRequest(at: Date().timeIntervalSince1970)

            model.confirmAutomaticUnlock(source: "screenState deadline=2.0")

            let entry = try #require(model.screenLockHistory.first)
            #expect(entry.isStillLocked)
            #expect(scripts.isEmpty)
        }
    }
}
