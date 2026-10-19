import Foundation

/// A three-valued boolean. The Mac never fabricates `false` when it cannot
/// determine the real state; it reports `unknown` instead.
public enum RemoteBooleanState: String, Codable, Sendable, Equatable {
    case yes
    case no
    case unknown

    public init(_ value: Bool?) {
        switch value {
        case .some(true): self = .yes
        case .some(false): self = .no
        case .none: self = .unknown
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .yes: return true
        case .no: return false
        case .unknown: return nil
        }
    }
}

/// The Mac state returned with every command response.
public struct MacRemoteState: Codable, Sendable, Equatable {
    public var screenLocked: RemoteBooleanState
    public var canUnlock: RemoteBooleanState
    public var hasCredential: RemoteBooleanState
    public var accessibilityGranted: RemoteBooleanState
    public var displaySleeping: RemoteBooleanState?
    /// Output level in `0...1`, or `nil` when this Mac has no display whose
    /// backlight can be driven.
    ///
    /// `nil` is also what an older Mac build decodes to, because it sends no
    /// such field at all. That is deliberate: the client offers a slider only
    /// when a real value arrives, instead of inferring support from a version
    /// number and then failing on the first drag.
    public var brightness: Double?
    /// Output volume in `0...1`, or `nil` when there is no output device with a
    /// volume control.
    public var volume: Double?
    /// `nil` when the output device has no mute control.
    public var volumeMuted: RemoteBooleanState?
    /// `yes` when the Mac injects pointer motion through its own virtual HID
    /// device, so the phone must send raw finger deltas — macOS applies its
    /// own pointer acceleration on top, and stacking the phone's curve would
    /// double it. `no` (or `nil` from an older Mac build) means the phone
    /// keeps its own acceleration curve.
    public var realtimeInputSystemAcceleration: RemoteBooleanState?
    /// Set in the trackpad begin response. Missing means an older Mac build.
    public var remoteTextInputAvailable: RemoteBooleanState?

    public init(
        screenLocked: RemoteBooleanState = .unknown,
        canUnlock: RemoteBooleanState = .unknown,
        hasCredential: RemoteBooleanState = .unknown,
        accessibilityGranted: RemoteBooleanState = .unknown,
        displaySleeping: RemoteBooleanState? = nil,
        brightness: Double? = nil,
        volume: Double? = nil,
        volumeMuted: RemoteBooleanState? = nil,
        realtimeInputSystemAcceleration: RemoteBooleanState? = nil,
        remoteTextInputAvailable: RemoteBooleanState? = nil
    ) {
        self.screenLocked = screenLocked
        self.canUnlock = canUnlock
        self.hasCredential = hasCredential
        self.accessibilityGranted = accessibilityGranted
        self.displaySleeping = displaySleeping
        self.brightness = brightness
        self.volume = volume
        self.volumeMuted = volumeMuted
        self.realtimeInputSystemAcceleration = realtimeInputSystemAcceleration
        self.remoteTextInputAvailable = remoteTextInputAvailable
    }
}

/// Payload for `setBrightness` and `setVolume`.
///
/// The level is normalized to `0...1` so the phone owns the scale it presents;
/// the Mac clamps anything outside that range rather than trusting the peer.
public struct RemoteLevelRequest: Codable, Sendable, Equatable {
    public let value: Double
    /// Volume only. `nil` leaves the mute state exactly as it was, so dragging
    /// the slider never silently un-mutes a deliberately muted Mac.
    public let muted: Bool?

    public init(value: Double, muted: Bool? = nil) {
        self.value = value
        self.muted = muted
    }

    /// `value` restricted to the only range the wire format promises.
    public var clampedValue: Double { min(max(value, 0), 1) }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }

    /// `nil` for a missing or undecodable payload, which the server reports as
    /// `invalidMessage` instead of guessing a level.
    public static func decoded(from payload: Data?) -> RemoteLevelRequest? {
        guard let payload, !payload.isEmpty else { return nil }
        return try? JSONDecoder().decode(RemoteLevelRequest.self, from: payload)
    }
}

/// Payload for `claimBLEIdentity`.
///
/// The phone chooses a random token and sends it over the authenticated,
/// encrypted network session; it then publishes the same token on the BLE
/// identity characteristic. The Mac reads that characteristic during its
/// bounded discovery attempt and learns the peripheral UUID only on a match.
/// The GATT read is what makes this reliable: the L2CAP handshake that used to
/// carry the proof can fail with `CBErrorDomain/0` before any byte flows.
public struct RemoteBLEIdentityClaim: Codable, Sendable, Equatable {
    /// Eight bytes fit an ordinary legacy BLE advertisement if this ever needs
    /// to move into service data, and are ample for a token that only lives in
    /// the paired client's authenticated session for half a minute.
    public static let tokenLength = 8
    /// A claim must be short-lived; the Mac clamps the requested window to this.
    public static let maximumValidity: TimeInterval = 120

    public let token: Data
    public let validity: TimeInterval

    public init(token: Data, validity: TimeInterval = 30) {
        self.token = token
        self.validity = validity
    }

    public var isValid: Bool {
        token.count == Self.tokenLength && validity > 0 && validity <= Self.maximumValidity
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }

    /// `nil` for a missing, undecodable, oversized or expired-by-construction
    /// claim, which the server reports as `invalidMessage`.
    public static func decoded(from payload: Data?) -> RemoteBLEIdentityClaim? {
        guard let payload, !payload.isEmpty,
              let claim = try? JSONDecoder().decode(RemoteBLEIdentityClaim.self, from: payload),
              claim.isValid else { return nil }
        return claim
    }
}

/// Stable, localized-on-the-client error vocabulary. Raw macOS errors never
/// cross the network; the iPhone maps these codes to human readable text.
public enum RemoteErrorCode: String, Codable, Sendable, Equatable, CaseIterable {
    case unauthenticated
    case pairingRequired
    case unsupportedProtocol
    case unsupportedCommand

    case accessibilityPermissionRequired
    case credentialNotConfigured

    case alreadyLocked
    case alreadyUnlocked

    case unlockFailed
    case wakeFailed
    case lockFailed
    case displaySleepFailed
    case commandTimeout
    /// No display on this Mac has a backlight that can be driven.
    case brightnessUnavailable
    /// No output device on this Mac exposes a volume control.
    case volumeUnavailable
    case textInputUnavailable
    case screenRecordingPermissionRequired
    case remoteVideoUnavailable

    /// This Mac cannot drive Sidecar at all: the framework is missing or the
    /// machine is not supported. Distinct from an empty device list, which
    /// means "supported, nothing in reach".
    case sidecarUnavailable
    /// The requested iPad is not in the Mac's current device list, so there is
    /// nothing to address a session to.
    case sidecarDeviceNotFound
    /// The requested iPad already has a Sidecar session.
    case sidecarAlreadyConnected
    /// Another Sidecar connect/disconnect is still in flight.
    case sidecarOperationInProgress
    /// The framework refused because the iPad itself is unreachable — asleep,
    /// locked or off Wi-Fi. Reported separately from a generic failure because
    /// the fix belongs to the iPad, not to MacPilot.
    case sidecarDeviceUnreachable
    case sidecarConnectFailed
    case sidecarDisconnectFailed

    case replayDetected
    case invalidMessage
    case internalError
}

public struct RemoteError: Codable, Sendable, Equatable {
    public let code: RemoteErrorCode
    /// Optional diagnostic detail. Never contains credentials, keys or payloads.
    public let message: String?

    public init(code: RemoteErrorCode, message: String? = nil) {
        self.code = code
        self.message = message
    }
}

public struct RemoteRequest: Codable, Sendable, Equatable {
    public let version: Int
    public let requestID: UUID
    public let command: RemoteCommand
    /// Milliseconds since the Unix epoch, used for freshness checks.
    public let timestamp: Int64
    /// Monotonic per-session counter, used for replay protection.
    public let sequence: UInt64
    public let payload: Data?

    public init(
        version: Int = RemoteProtocolVersion.current,
        requestID: UUID = UUID(),
        command: RemoteCommand,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        sequence: UInt64,
        payload: Data? = nil
    ) {
        self.version = version
        self.requestID = requestID
        self.command = command
        self.timestamp = timestamp
        self.sequence = sequence
        self.payload = payload
    }
}

public struct RemoteResponse: Codable, Sendable, Equatable {
    public let version: Int
    public let requestID: UUID
    public let success: Bool
    public let error: RemoteError?
    public let state: MacRemoteState?
    /// Command specific answer, e.g. a `RemoteDockGroupsSnapshot` for the Dock
    /// group commands. Optional in both directions: older peers that neither
    /// send nor expect a payload keep decoding this response unchanged.
    public let payload: Data?

    public init(
        version: Int = RemoteProtocolVersion.current,
        requestID: UUID,
        success: Bool,
        error: RemoteError? = nil,
        state: MacRemoteState? = nil,
        payload: Data? = nil
    ) {
        self.version = version
        self.requestID = requestID
        self.success = success
        self.error = error
        self.state = state
        self.payload = payload
    }
}

// MARK: - Dock groups

/// How a Dock group's icon is drawn. Mirrors the Mac's `DockGroupIconSource`
/// so the phone can pick a close rendering: SF Symbols map 1:1, an emoji is
/// text, and the two image-backed sources fall back to a placeholder.
public enum RemoteDockGroupIconSource: String, Codable, Sendable, Equatable, CaseIterable {
    case symbol
    case emoji
    case composite
    case customImage
}

/// One member app of a Dock group, as the phone renders it. Running state is
/// computed when the snapshot is built, so it is a moment-in-time view.
public struct RemoteDockGroupAppSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let isRunning: Bool

    public init(id: UUID, name: String, isRunning: Bool) {
        self.id = id
        self.name = name
        self.isRunning = isRunning
    }
}

/// One Dock group on the Mac.
public struct RemoteDockGroupSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let iconSource: RemoteDockGroupIconSource
    /// SF Symbol name, emoji text, or an opaque file name for image-backed
    /// sources — the phone never fetches that image and renders a placeholder.
    public let iconValue: String
    public let apps: [RemoteDockGroupAppSummary]

    public init(
        id: String,
        name: String,
        iconSource: RemoteDockGroupIconSource,
        iconValue: String,
        apps: [RemoteDockGroupAppSummary]
    ) {
        self.id = id
        self.name = name
        self.iconSource = iconSource
        self.iconValue = iconValue
        self.apps = apps
    }
}

/// The full Dock group listing. Rides in the payload of `getDockGroups`, and
/// in the reply of both launch commands so the phone can refresh its rows from
/// the same round trip.
public struct RemoteDockGroupsSnapshot: Codable, Sendable, Equatable {
    public let groups: [RemoteDockGroupSummary]
    /// `launchDockGroup` / `launchDockGroupApp` only: names of members the Mac
    /// could not resolve or launch (deleted, moved, broken). `nil` on
    /// `getDockGroups`. A launch that cannot find the group at all is an
    /// error response, not an empty list here.
    public let missingApps: [String]?

    public init(groups: [RemoteDockGroupSummary], missingApps: [String]? = nil) {
        self.groups = groups
        self.missingApps = missingApps
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }

    /// `nil` for a missing or undecodable payload.
    public static func decoded(from payload: Data?) -> RemoteDockGroupsSnapshot? {
        guard let payload, !payload.isEmpty else { return nil }
        return try? JSONDecoder().decode(RemoteDockGroupsSnapshot.self, from: payload)
    }
}

/// Payload for `launchDockGroup` and `launchDockGroupApp`. A `nil` `appID`
/// launches every member of the group.
public struct RemoteDockGroupLaunchRequest: Codable, Sendable, Equatable {
    public let groupID: String
    public let appID: UUID?

    public init(groupID: String, appID: UUID? = nil) {
        self.groupID = groupID
        self.appID = appID
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }

    /// `nil` for a missing or undecodable payload, which the server reports as
    /// `invalidMessage` instead of guessing what to launch.
    public static func decoded(from payload: Data?) -> RemoteDockGroupLaunchRequest? {
        guard let payload, !payload.isEmpty else { return nil }
        return try? JSONDecoder().decode(RemoteDockGroupLaunchRequest.self, from: payload)
    }
}

// MARK: - Sidecar

/// What the Mac is doing with Sidecar right now. A finished connect clears the
/// operation and marks the device connected instead, so `isConnected` on the
/// wire always comes from the system's own connected-device list, never from
/// the fact that a command was accepted.
public enum RemoteSidecarPhase: String, Codable, Sendable, Equatable {
    case connecting
    case disconnecting
    case failed
}

/// One iPad the Mac can reach as a Sidecar target.
///
/// `id` is the framework's device UUID. The name is decoration only: two iPads
/// can be called "iPad", and addressing a session by name would connect the
/// wrong one.
public struct RemoteSidecarDevice: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// Hardware model ("iPad16,1"), when the framework reports one. Shown as a
    /// subtitle so two same-named iPads stay distinguishable.
    public let model: String?
    public let isConnected: Bool

    public init(id: String, name: String, model: String? = nil, isConnected: Bool) {
        self.id = id
        self.name = name
        self.model = model
        self.isConnected = isConnected
    }
}

/// The Sidecar operation in flight, or the last one that failed. Rides in every
/// snapshot so a poll never has to guess whether a device that is not connected
/// yet is still on its way or already gave up.
public struct RemoteSidecarOperation: Codable, Sendable, Equatable {
    public let deviceID: String
    public let phase: RemoteSidecarPhase
    /// `.failed` only, and always one of the stable `sidecar*` codes.
    public let errorCode: RemoteErrorCode?

    public init(deviceID: String, phase: RemoteSidecarPhase, errorCode: RemoteErrorCode? = nil) {
        self.deviceID = deviceID
        self.phase = phase
        self.errorCode = errorCode
    }
}

/// The whole Sidecar picture: what the Mac can see, what is connected, and what
/// it is currently doing. Rides in the payload of all three Sidecar commands.
public struct RemoteSidecarSnapshot: Codable, Sendable, Equatable {
    public let devices: [RemoteSidecarDevice]
    public let operation: RemoteSidecarOperation?

    public init(devices: [RemoteSidecarDevice], operation: RemoteSidecarOperation? = nil) {
        self.devices = devices
        self.operation = operation
    }

    /// The device currently connected, if the system reports one. Sidecar
    /// drives a single iPad at a time, so this is what a target switch has to
    /// tear down first.
    public var connectedDevice: RemoteSidecarDevice? { devices.first(where: \.isConnected) }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }

    /// `nil` for a missing or undecodable payload.
    public static func decoded(from payload: Data?) -> RemoteSidecarSnapshot? {
        guard let payload, !payload.isEmpty else { return nil }
        return try? JSONDecoder().decode(RemoteSidecarSnapshot.self, from: payload)
    }
}

/// Payload for `connectSidecar` and `disconnectSidecar`.
public struct RemoteSidecarTargetRequest: Codable, Sendable, Equatable {
    public let deviceID: String

    public init(deviceID: String) {
        self.deviceID = deviceID
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }

    /// `nil` for a missing or undecodable payload, which the server reports as
    /// `invalidMessage` rather than picking a device on its own.
    public static func decoded(from payload: Data?) -> RemoteSidecarTargetRequest? {
        guard let payload, !payload.isEmpty else { return nil }
        return try? JSONDecoder().decode(RemoteSidecarTargetRequest.self, from: payload)
    }
}

/// Flat handshake envelope. A single optional-heavy struct keeps Codable
/// straightforward and makes the wire format easy to inspect in tests.
public struct RemoteHandshakeMessage: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case clientHello
        case serverHello
        case pairRequest
        case pairResult
        case pairConfirm
        case authRequest
        case authResult
        case failure
    }

    public var kind: Kind
    public var protocolVersion: Int
    public var clientID: UUID?
    public var clientName: String?
    public var deviceID: UUID?
    public var deviceName: String?
    public var paired: Bool?
    public var clientNonce: Data?
    public var serverNonce: Data?
    public var publicKey: Data?
    public var proof: Data?
    public var pairCode: String?
    public var capabilities: [RemoteCapability]?
    public var features: [String]?
    public var errorCode: RemoteErrorCode?
    public var errorMessage: String?

    public init(
        kind: Kind,
        protocolVersion: Int = RemoteProtocolVersion.current,
        clientID: UUID? = nil,
        clientName: String? = nil,
        deviceID: UUID? = nil,
        deviceName: String? = nil,
        paired: Bool? = nil,
        clientNonce: Data? = nil,
        serverNonce: Data? = nil,
        publicKey: Data? = nil,
        proof: Data? = nil,
        pairCode: String? = nil,
        capabilities: [RemoteCapability]? = nil,
        features: [String]? = nil,
        errorCode: RemoteErrorCode? = nil,
        errorMessage: String? = nil
    ) {
        self.kind = kind
        self.protocolVersion = protocolVersion
        self.clientID = clientID
        self.clientName = clientName
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.paired = paired
        self.clientNonce = clientNonce
        self.serverNonce = serverNonce
        self.publicKey = publicKey
        self.proof = proof
        self.pairCode = pairCode
        self.capabilities = capabilities
        self.features = features
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }
}
