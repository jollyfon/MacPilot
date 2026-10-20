import AppKit
import SwiftUI

/// Visible on both Home and Remote Control, including for existing users whose
/// saved system permission no longer allows device discovery.
struct RemoteLocalNetworkNotice: View {
    @EnvironmentObject private var model: MacPilotModel
    @ObservedObject var server: RemoteControlServer

    var body: some View {
        if let content {
            VStack(alignment: .leading, spacing: 10) {
                Label(model.t("remoteNetworkNoticeTitle"), systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text(line("remoteNetworkNoticeProblemLine", content.problemKey, content.arguments))
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(line("remoteNetworkNoticeStepsLine", content.stepsKey, content.arguments))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if content.isCurrentConsoleAccountDenied {
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

    private enum Content {
        case currentConsoleAccountDenied
        case otherConsoleUser(console: String, process: String)
        case failed

        var problemKey: String {
            switch self {
            case .currentConsoleAccountDenied: return "remoteNetworkDeniedProblem"
            case .otherConsoleUser: return "remoteNetworkOtherConsoleUserProblem"
            case .failed: return "remoteNetworkFailedProblem"
            }
        }

        var stepsKey: String {
            switch self {
            case .currentConsoleAccountDenied: return "remoteNetworkDeniedSteps"
            case .otherConsoleUser: return "remoteNetworkOtherConsoleUserSteps"
            case .failed: return "remoteNetworkFailedSteps"
            }
        }

        var arguments: [CVarArg] {
            switch self {
            case .currentConsoleAccountDenied, .failed: return []
            case let .otherConsoleUser(console, process): return [console, process]
            }
        }

        var isCurrentConsoleAccountDenied: Bool {
            if case .currentConsoleAccountDenied = self { return true }
            return false
        }
    }

    private var content: Content? {
        switch server.bonjourStatus {
        case .permissionDenied:
            guard let otherConsoleUser else { return .currentConsoleAccountDenied }
            return .otherConsoleUser(
                console: otherConsoleUser,
                process: LocalNetworkSessionDiagnosis.processUserName()
            )
        case .failed:
            return .failed
        default:
            return nil
        }
    }

    private func line(_ labelKey: String, _ bodyKey: String, _ arguments: [CVarArg]) -> String {
        model.t(labelKey, AppText.value(bodyKey, language: model.language, arguments: arguments))
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
