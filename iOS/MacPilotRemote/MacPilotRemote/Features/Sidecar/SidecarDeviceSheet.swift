import MacPilotRemoteProtocol
import SwiftUI

/// The iPads the connected Mac can drive as Sidecar displays.
///
/// The phone is only the remote here: the Mac discovers the devices and owns the
/// session, so this sheet shows what the Mac last reported and hands it one
/// request at a time. Closing it never ends a running session.
struct SidecarDeviceSheet: View {
    @EnvironmentObject private var appModel: RemoteAppModel
    @Environment(\.dismiss) private var dismiss

    /// The iPad a target switch is being confirmed for. Switching ends another
    /// iPad's session, which is the one thing here worth asking about first.
    @State private var switchTarget: RemoteSidecarDevice?

    private var state: SidecarPanelPolicy.PanelState {
        SidecarPanelPolicy.panelState(
            isConnected: appModel.connectionState.isConnected,
            snapshot: appModel.sidecarSnapshot,
            didFailToLoad: appModel.didFailToLoadSidecar
        )
    }

    private var isInteractive: Bool {
        SidecarPanelPolicy.canSendTargetRequest(
            snapshot: appModel.sidecarSnapshot,
            isRequestInFlight: appModel.sidecarRequestInFlight != nil
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                if let errorKey = appModel.errorKey {
                    errorRow(errorKey)
                }
                switch state {
                case .ready:
                    deviceSection
                case .loading:
                    statusSection(spins: true, title: "sidecarLoading", detail: nil)
                case .empty:
                    statusSection(icon: "ipad", title: "sidecarEmpty", detail: "sidecarEmptyHint")
                case .unreachable:
                    statusSection(icon: "exclamationmark.triangle",
                                  title: "sidecarUnavailable", detail: "sidecarUnavailableHint")
                    retryRow
                case .macDisconnected:
                    statusSection(icon: "desktopcomputer",
                                  title: "sidecarNotConnected", detail: "sidecarNotConnectedHint")
                }
                footerRow
            }
            .navigationTitle(appModel.text("sidecarTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(appModel.text("sidecarDone")) { dismiss() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    refreshButton
                }
            }
            .confirmationDialog(
                appModel.text("sidecarSwitchTitle"),
                isPresented: Binding(
                    get: { switchTarget != nil },
                    set: { if !$0 { switchTarget = nil } }
                ),
                titleVisibility: .visible,
                presenting: switchTarget
            ) { device in
                Button(appModel.text("sidecarSwitchConfirm"), role: .destructive) {
                    switchTarget = nil
                    appModel.connectSidecar(deviceID: device.id)
                }
                Button(appModel.text("sidecarCancel"), role: .cancel) { switchTarget = nil }
            } message: { device in
                Text(appModel.text("sidecarSwitchMessage", device.name))
            }
        }
        .presentationDetents([.medium, .large])
        // The model polls only while this sheet is up, so appearing and
        // disappearing is what arms and disarms the refresh.
        .onAppear { appModel.setSidecarPanelVisible(true) }
        .onDisappear { appModel.setSidecarPanelVisible(false) }
    }

    // MARK: - Devices

    private var deviceSection: some View {
        Section {
            ForEach(appModel.sidecarSnapshot?.devices ?? []) { device in
                deviceRow(device)
            }
        } header: {
            Text(appModel.text("sidecarDevicesHeader"))
        }
    }

    private func deviceRow(_ device: RemoteSidecarDevice) -> some View {
        let status = SidecarPanelPolicy.rowStatus(
            device: device,
            operation: appModel.sidecarSnapshot?.operation
        )
        return Button {
            tap(device)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: device.isConnected ? "rectangle.on.rectangle.angled" : "ipad")
                    .font(.body)
                    .foregroundStyle(device.isConnected ? Color.accentColor : Color.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let subtitle = subtitle(device) {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                trailing(status)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!isInteractive)
        .opacity(isInteractive ? 1 : 0.5)
        .accessibilityLabel(accessibilityLabel(device, status: status))
        .accessibilityIdentifier("sidecar.\(device.id)")
    }

    /// The hardware model is what tells two iPads both called "iPad" apart, and
    /// the remembered target is marked rather than moved to the top: the Mac's
    /// own order is the one the user compares System Settings against.
    private func subtitle(_ device: RemoteSidecarDevice) -> String? {
        var parts: [String] = []
        if let model = device.model, !model.isEmpty { parts.append(model) }
        if device.id == appModel.lastSidecarDeviceID { parts.append(appModel.text("sidecarLastUsed")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func trailing(_ status: SidecarPanelPolicy.RowStatus) -> some View {
        switch status {
        case .idle:
            Text(appModel.text("sidecarConnect"))
                .font(.subheadline)
                .foregroundStyle(Color.accentColor)
        case .connected:
            Text(appModel.text("sidecarDisconnect"))
                .font(.subheadline)
                .foregroundStyle(.orange)
        case .connecting:
            busyLabel("sidecarConnecting")
        case .disconnecting:
            busyLabel("sidecarDisconnecting")
        case .failed(let key):
            Text(appModel.text(key))
                .font(.caption)
                .foregroundStyle(.red)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 150)
        }
    }

    private func busyLabel(_ key: String) -> some View {
        HStack(spacing: 6) {
            ProgressView()
            Text(appModel.text(key))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func accessibilityLabel(_ device: RemoteSidecarDevice,
                                    status: SidecarPanelPolicy.RowStatus) -> String {
        var parts = [device.name]
        if let model = device.model, !model.isEmpty { parts.append(model) }
        if let key = status.statusKey { parts.append(appModel.text(key)) }
        return parts.joined(separator: ", ")
    }

    /// One tap does the obvious thing: a connected iPad disconnects, a free one
    /// connects. Only a target switch detours, because it ends a session that is
    /// on screen right now.
    private func tap(_ device: RemoteSidecarDevice) {
        guard isInteractive else { return }
        if device.isConnected {
            appModel.disconnectSidecar(deviceID: device.id)
        } else if SidecarPanelPolicy.requiresSwitchConfirmation(
            snapshot: appModel.sidecarSnapshot, targetID: device.id
        ) {
            switchTarget = device
        } else {
            appModel.connectSidecar(deviceID: device.id)
        }
    }

    // MARK: - States

    private func statusSection(icon: String? = nil, spins: Bool = false,
                               title: String, detail: String?) -> some View {
        Section {
            HStack(spacing: 12) {
                if spins {
                    ProgressView()
                        .frame(width: 28)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 28)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(appModel.text(title)).font(.subheadline)
                    if let detail {
                        Text(appModel.text(detail))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
        }
    }

    private var retryRow: some View {
        Section {
            Button(appModel.text("retry")) {
                Task { await appModel.refreshSidecarDevices(userInitiated: true) }
            }
            .accessibilityIdentifier("sidecar.retry")
        }
    }

    /// The Mac's own verdict, or a lost request. Shown here as well as on the
    /// home banner behind the sheet: a refusal is the answer to the tap the user
    /// just made, and it should not wait for them to close the panel.
    private func errorRow(_ key: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(appModel.text(key))
                .font(.footnote)
            Spacer(minLength: 0)
            Button {
                appModel.clearMessages()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(appModel.text("sidecarDismissError"))
        }
        .listRowBackground(Color.orange.opacity(0.12))
    }

    /// Said plainly, because it is the part a remote control gets wrong most
    /// often: this sheet is a window onto the Mac's session, not the owner of it.
    private var footerRow: some View {
        Section {
            Text(appModel.text("sidecarFooter"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// A poll is not an answer, and an iPad that just woke up should not have to
    /// wait for the next tick.
    private var refreshButton: some View {
        Button {
            Task { await appModel.refreshSidecarDevices(userInitiated: true) }
        } label: {
            if appModel.isRefreshingSidecarList {
                ProgressView()
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .disabled(!appModel.connectionState.isConnected || appModel.isRefreshingSidecarList)
        .accessibilityLabel(appModel.text("sidecarRefresh"))
    }
}
