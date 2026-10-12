import Darwin
import Foundation
import MacPilotRemoteProtocol
import Network

/// A MacPilot instance seen on the local network.
struct DiscoveredMac: Identifiable, Equatable {
    let id: UUID
    var name: String
    var endpoint: NWEndpoint
    var serviceName: String?
    var version: String
    var protocolVersion: Int
    var capabilities: Set<RemoteCapability>

    var canUnlock: Bool { capabilities.contains(.unlock) }
}

/// One Mac this iPhone has paired with. The pairing key itself lives in the
/// Keychain and is never part of this model.
struct PairedMac: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var lastServiceName: String?
    var lastHost: String?
    var lastPort: UInt16?
    var lastConnectedAt: Date?
    var manualHost: String?
    var manualPort: UInt16?

    var manualEndpoint: NWEndpoint? {
        guard let manualHost, let manualPort, let port = NWEndpoint.Port(rawValue: manualPort) else { return nil }
        return .hostPort(host: NWEndpoint.Host(manualHost), port: port)
    }

    var deviceID: UUID? { UUID(uuidString: id) }

    /// Endpoint remembered from the previous successful connection, used for the
    /// fast path when the app opens.
    var rememberedEndpoint: NWEndpoint? {
        guard let lastHost, let lastPort, let port = NWEndpoint.Port(rawValue: lastPort) else { return nil }
        return .hostPort(host: NWEndpoint.Host(lastHost), port: port)
    }

    /// Resolve a fresh peer address when the saved link-local address has changed.
    var rememberedServiceEndpoint: NWEndpoint? {
        guard let lastServiceName, !lastServiceName.isEmpty else { return nil }
        return .service(name: lastServiceName, type: RemoteProtocolVersion.bonjourServiceType,
                        domain: "local.", interface: nil)
    }
}

/// One of the two continuous output levels on the remote panel. Each maps onto
/// the payload carrying command the Mac expects.
enum RemoteLevelKind: String, CaseIterable, Equatable {
    case brightness
    case volume

    var command: RemoteCommand {
        switch self {
        case .brightness: return .setBrightness
        case .volume: return .setVolume
        }
    }

    var labelKey: String {
        switch self {
        case .brightness: return "brightnessLabel"
        case .volume: return "volumeLabel"
        }
    }

    var iconName: String {
        switch self {
        case .brightness: return "sun.max.fill"
        case .volume: return "speaker.wave.2.fill"
        }
    }

    /// The level this kind reports in `MacRemoteState`, or `nil` when this Mac
    /// cannot provide it.
    func value(in state: MacRemoteState?) -> Double? {
        switch self {
        case .brightness: return state?.brightness
        case .volume: return state?.volume
        }
    }
}

/// Phase 7 instrumentation. Every value is measured on device; nothing is sent
/// anywhere.
struct RemoteMetrics: Equatable {
    var discoveryLatencyMs: Int?
    var connectLatencyMs: Int?
    var handshakeLatencyMs: Int?
    var commandRTTMs: Int?
    var executionLatencyMs: Int?
}

/// Unified connection state. The UI only ever switches on this value.
enum RemoteConnectionState: Equatable {
    case idle
    case discovering
    case connecting
    case pairing
    case authenticating
    case connected
    case reconnecting
    case failed(String)

    var isConnected: Bool { self == .connected }

    var isBusy: Bool {
        switch self {
        case .connecting, .pairing, .authenticating, .reconnecting, .discovering: return true
        case .idle, .connected, .failed: return false
        }
    }

    var titleKey: String {
        switch self {
        case .idle: return "stateIdle"
        case .discovering: return "stateDiscovering"
        case .connecting: return "stateConnecting"
        case .pairing: return "statePairing"
        case .authenticating: return "stateAuthenticating"
        case .connected: return "stateConnected"
        case .reconnecting: return "stateReconnecting"
        case .failed: return "stateFailed"
        }
    }
}

enum RemoteConnectionError: Error, Equatable {
    case unsupportedProtocol
    case pairingWindowClosed
    case invalidPairCode
    case authenticationFailed
    case notPaired
    case network(String)
    case server(RemoteErrorCode)

    var messageKey: String {
        switch self {
        case .unsupportedProtocol: return "errorUnsupportedProtocol"
        case .pairingWindowClosed: return "errorPairingWindowClosed"
        case .invalidPairCode: return "errorInvalidPairCode"
        case .authenticationFailed: return "errorAuthenticationFailed"
        case .notPaired: return "errorNotPaired"
        case .network: return "errorNetwork"
        case .server(let code): return code.messageKey
        }
    }
}

extension RemoteErrorCode {
    /// Human readable text key. The Mac never sends raw system errors, so the
    /// client owns the wording.
    var messageKey: String {
        switch self {
        case .unauthenticated: return "errorUnauthenticated"
        case .pairingRequired: return "errorPairingRequired"
        case .unsupportedProtocol: return "errorUnsupportedProtocol"
        case .unsupportedCommand: return "errorUnsupportedCommand"
        case .accessibilityPermissionRequired: return "errorAccessibility"
        case .credentialNotConfigured: return "errorCredential"
        case .alreadyLocked: return "errorAlreadyLocked"
        case .alreadyUnlocked: return "errorAlreadyUnlocked"
        case .unlockFailed: return "errorUnlockFailed"
        case .wakeFailed: return "errorWakeFailed"
        case .lockFailed: return "errorLockFailed"
        case .displaySleepFailed: return "errorDisplaySleepFailed"
        case .brightnessUnavailable: return "errorBrightnessUnavailable"
        case .volumeUnavailable: return "errorVolumeUnavailable"
        case .screenRecordingPermissionRequired: return "desktopPermission"
        case .remoteVideoUnavailable: return "desktopUnavailable"
        case .textInputUnavailable: return "errorTextInputUnavailable"
        case .commandTimeout: return "errorTimeout"
        case .sidecarUnavailable: return "errorSidecarUnavailable"
        case .sidecarDeviceNotFound: return "errorSidecarDeviceNotFound"
        case .sidecarAlreadyConnected: return "errorSidecarAlreadyConnected"
        case .sidecarOperationInProgress: return "errorSidecarOperationInProgress"
        case .sidecarDeviceUnreachable: return "errorSidecarDeviceUnreachable"
        case .sidecarConnectFailed: return "errorSidecarConnectFailed"
        case .sidecarDisconnectFailed: return "errorSidecarDisconnectFailed"
        case .replayDetected: return "errorNetwork"
        case .invalidMessage: return "errorNetwork"
        case .internalError: return "errorInternal"
        }
    }
}

/// A user-entered host and explicit TCP port; no URL schemes or embedded ports.
struct ManualMacAddress: Equatable {
    let host: String
    let port: UInt16

    init?(host: String, port: String) {
        var host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard let port = UInt16(port.trimmingCharacters(in: .whitespacesAndNewlines)), port > 0 else { return nil }
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        let isIP = host.withCString { inet_pton(AF_INET, $0, &ipv4) == 1 || inet_pton(AF_INET6, $0, &ipv6) == 1 }
        let dnsHost = host.hasSuffix(".") ? String(host.dropLast()) : host
        let labels = dnsHost.split(separator: ".", omittingEmptySubsequences: false)
        let isDNS = dnsHost.utf8.count <= 253 && labels.allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
        guard isIP || isDNS else { return nil }
        self.host = host
        self.port = port
    }

    var endpoint: NWEndpoint { .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!) }
}
