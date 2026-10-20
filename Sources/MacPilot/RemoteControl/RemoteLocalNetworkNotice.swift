import AppKit
import SwiftUI

/// Visible on both Home and Remote Control, including for existing users whose
/// saved system permission no longer allows device discovery.
struct RemoteLocalNetworkNotice: View {
    @EnvironmentObject private var model: MacPilotModel
    @ObservedObject var server: RemoteControlServer

    var body: some View {
        if hintKey != nil {
            VStack(alignment: .leading, spacing: 10) {
                Label(model.t("remoteControl"), systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text(hintText).font(.subheadline)
                if server.bonjourStatus == .permissionDenied, otherConsoleUser == nil {
                    HStack {
                        Button(model.t("remoteRelaunchMacPilot")) { Self.relaunch() }
                            .macPilotProminentButtonStyle()
                        Button(model.t("remoteOpenLocalNetworkSettings")) { Self.openSettings() }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.orange.opacity(0.35)))
        }
    }

    private var hintKey: String? {
        switch server.bonjourStatus {
        case .permissionDenied:
            return otherConsoleUser == nil
                ? "remoteNetworkDeniedHint"
                : "remoteNetworkOtherConsoleUserHint"
        case .failed: return "remoteNetworkFailedHint"
        default: return nil
        }
    }

    private var hintText: String {
        guard let hintKey else { return "" }
        guard let otherConsoleUser else { return model.t(hintKey) }
        return model.t(hintKey, otherConsoleUser, LocalNetworkSessionDiagnosis.processUserName())
    }

    /// Reopening the app or toggling the switch in this account cannot override
    /// the console account's policy, so only offer those actions when the
    /// console account is the one running MacPilot.
    private var otherConsoleUser: String? {
        guard server.bonjourStatus == .permissionDenied else { return nil }
        return LocalNetworkSessionDiagnosis.otherConsoleUser(
            consoleUser: server.localNetworkConsoleUser,
            processUser: LocalNetworkSessionDiagnosis.processUserName()
        )
    }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") else { return }
        NSWorkspace.shared.open(url)
    }

    /// A -65570 denial can outlive an in-place update, so reopen after this process exits.
    static func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; exec /usr/bin/open -n \"$1\"", "macpilot-relaunch", bundleURL.path]
        do {
            try process.run()
        } catch {
            return
        }
        NSApplication.shared.terminate(nil)
    }
}
