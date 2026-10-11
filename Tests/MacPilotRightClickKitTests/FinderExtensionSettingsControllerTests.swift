import Foundation
import Testing
@testable import MacPilotRightClickKit

@MainActor
struct FinderExtensionSettingsControllerTests {
    @Test func clickingTheSwitchChangesTheSystemElectionAndKeepsTheConfirmedCheckmark() async {
        var elected = false
        var requests: [Bool] = []
        let controller = FinderExtensionSettingsController { requested in
            if let requested {
                requests.append(requested)
                elected = requested
            }
            return elected
        }
        await controller.refresh()
        #expect(!controller.isEnabled)
        await controller.setEnabled(true)
        #expect(controller.isEnabled)
        #expect(requests == [true])
        await controller.setEnabled(false)
        #expect(!controller.isEnabled)
        #expect(requests == [true, false])
    }

    @Test func failedChangePreservesConfirmedStateAndShowsAnError() async {
        enum Failure: Error { case denied }
        let controller = FinderExtensionSettingsController { requested in
            if requested != nil { throw Failure.denied }
            return true
        }
        await controller.refresh()
        await controller.setEnabled(false)
        #expect(controller.isEnabled)
        #expect(controller.errorMessage != nil)
        #expect(!controller.isBusy)
    }

    @Test func returningFromSystemSettingsRefreshesTheCheckmark() async {
        var elected = false
        let controller = FinderExtensionSettingsController { _ in elected }
        await controller.refresh()
        elected = true
        await controller.refresh()
        #expect(controller.isEnabled)
    }

    @Test func partialFailureReloadsTheRealStateInsteadOfLeavingAStaleCheckmark() async {
        enum Failure: Error { case registration }
        var elected = true
        let controller = FinderExtensionSettingsController { requested in
            if requested != nil {
                elected = false
                throw Failure.registration
            }
            return elected
        }
        await controller.refresh()
        #expect(controller.isEnabled)
        await controller.setEnabled(false)
        #expect(!controller.isEnabled)
        #expect(controller.errorMessage != nil)
    }
}
