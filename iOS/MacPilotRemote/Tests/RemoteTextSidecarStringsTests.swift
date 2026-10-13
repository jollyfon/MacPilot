import Foundation
import Testing
@testable import PilotNest

/// The XCUITest that watches the Sidecar sheet asserts over an *or* list of
/// acceptable reasons, and in the simulator the sheet renders the disconnected
/// branch — so it can pass while a `sidecarUnsupported` rewording goes unnoticed.
/// This test is the part that actually pins both tables.
struct RemoteTextSidecarStringsTests {
    /// Every key `SidecarDeviceSheet`, `SidecarPanelPolicy` and the home entry
    /// render. Dropping one from this list means dropping it from the app.
    private let renderedKeys = [
        "sidecarEntry", "sidecarTitle", "sidecarDone", "sidecarCancel",
        "sidecarRefresh", "sidecarDismissError", "sidecarDevicesHeader",
        "sidecarConnect", "sidecarDisconnect", "sidecarConnected",
        "sidecarConnecting", "sidecarDisconnecting", "sidecarFailed",
        "sidecarLastUsed", "sidecarLoading", "sidecarEmpty", "sidecarEmptyHint",
        "sidecarUnavailable", "sidecarUnavailableHint", "sidecarNotConnected",
        "sidecarNotConnectedHint", "sidecarUnsupported", "sidecarUnsupportedHint",
        "sidecarFooter", "sidecarSwitchTitle", "sidecarSwitchMessage",
        "sidecarSwitchConfirm"
    ]

    @Test func everySidecarStringIsWrittenInBothLocales() {
        // `value` falls back to the English table, so "not equal to the key" does
        // not prove a Chinese entry exists — being *different from the English
        // wording* does.
        for key in renderedKeys {
            let chinese = RemoteText.value(key, language: .simplifiedChinese)
            let english = RemoteText.value(key, language: .english)
            #expect(chinese != key, "\(key) is missing from every table")
            #expect(!english.isEmpty, "\(key) has no English wording")
            #expect(chinese != english, "\(key) has no Simplified Chinese wording")
        }
    }

    @Test func aMacWithoutTheFeatureBlamesTheMacRatherThanTheUser() {
        // The honesty rule for the row the user switched on: when Sidecar cannot
        // run, the sentence names the thing that is actually missing — a MacPilot
        // build with the feature on that Mac — and never implies the iPad or the
        // user's hardware was rejected.
        for language in [RemoteText.Language.simplifiedChinese, .english] {
            let reason = RemoteText.value("sidecarUnsupported", language: language)
            #expect(reason.contains("Mac"))
            #expect(reason.contains("MacPilot"))
        }
    }

    @Test func theSwitchWarningStillSubstitutesTheDeviceNameInBothLocales() {
        #expect(RemoteText.value("sidecarSwitchMessage", language: .english, "iPad Pro")
            .contains("iPad Pro"))
        #expect(RemoteText.value("sidecarSwitchMessage", language: .simplifiedChinese, "iPad Pro")
            .contains("iPad Pro"))
        #expect(RemoteText.value("notASidecarKey") == "notASidecarKey")
    }
}
