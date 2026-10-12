import Foundation
import ObjectiveC

/// One iPad as SidecarCore reports it.
struct SidecarBridgeDevice: Equatable, Sendable {
    /// The framework's device UUID. Sessions are addressed by this, never by
    /// name: two iPads can share a display name.
    let identifier: String
    let name: String
    let model: String?
}

/// The facts `SidecarService` needs before it decides anything.
struct SidecarBridgeState: Equatable, Sendable {
    let isSupported: Bool
    /// Every iPad the Mac can currently address, in framework order.
    let devices: [SidecarBridgeDevice]
    /// Identifiers holding a session right now, straight from the framework's
    /// own connected list — the only source this code trusts for "connected".
    let connectedIdentifiers: [String]

    static let unsupported = SidecarBridgeState(isSupported: false, devices: [], connectedIdentifiers: [])
}

enum SidecarBridgeError: Error, Equatable {
    /// The framework, a class or a selector this macOS build does not have.
    case unsupported
    /// The identifier is not in the current device list.
    case deviceMissing
    /// The framework answered with an error. Domain and code stay in the Mac's
    /// log; the wire carries a stable code instead.
    case refused(domain: String, code: Int)
}

/// The Sidecar surface the app drives. A protocol so no test ever loads a
/// private framework, and so the whole state machine can be exercised against a
/// stub that answers in the order the real one does.
@MainActor
protocol SidecarCoreBridge: AnyObject {
    var isSupported: Bool { get }
    func currentState() -> SidecarBridgeState
    /// `nil` when the framework reported success.
    func connect(deviceID: String) async -> SidecarBridgeError?
    func disconnect(deviceID: String) async -> SidecarBridgeError?
}

/// Talks to the private `SidecarCore` framework through the Objective-C runtime.
///
/// No symbol may be assumed to exist: the framework ships no module map and
/// promises no stability, so the handle, both classes and every selector are
/// resolved at runtime and anything missing degrades to `.unsupported` instead
/// of trapping. The selectors below were verified by runtime introspection on
/// macOS 27.0.1 (26A434) and match the published macOS 26.4 headers:
/// `+sharedManager`, `+isSupported`, `-devices`, `-connectedDevices`,
/// `-connectToDevice:completion:` and `-disconnectFromDevice:completion:` (both
/// completions are `void (^)(NSError * _Nullable)`).
@MainActor
final class SidecarCoreRuntime: SidecarCoreBridge {
    /// The binary lives in the dyld shared cache, but `dlopen` on the framework
    /// path still resolves it — and PrivateFrameworks is not in the fallback
    /// search path, so the full path is required.
    private static let frameworkPath = "/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore"
    private static let managerClassName = "SidecarDisplayManager"

    private var managerClass: NSObject.Type?
    private var manager: NSObject?
    private var supported = false
    private var didAttemptLoad = false
    private let log: (String) -> Void

    init(log: @escaping (String) -> Void = { _ in }) {
        self.log = log
    }

    var isSupported: Bool {
        loadIfNeeded()
        return supported
    }

    func currentState() -> SidecarBridgeState {
        guard supported, let manager = sharedManager() else { return .unsupported }
        return SidecarBridgeState(
            isSupported: true,
            devices: Self.readDevices(from: manager, key: "devices"),
            connectedIdentifiers: Self.readDevices(from: manager, key: "connectedDevices").map(\.identifier)
        )
    }

    func connect(deviceID: String) async -> SidecarBridgeError? {
        await invoke("connectToDevice:completion:", deviceID: deviceID)
    }

    func disconnect(deviceID: String) async -> SidecarBridgeError? {
        await invoke("disconnectFromDevice:completion:", deviceID: deviceID)
    }

    // MARK: - Loading

    /// Deferred to the first question about Sidecar: a Mac whose remote control
    /// is switched off, or a phone that never asks, must not pay for loading a
    /// private framework.
    private func loadIfNeeded() {
        guard !didAttemptLoad else { return }
        didAttemptLoad = true
        guard dlopen(Self.frameworkPath, RTLD_NOW) != nil,
              let managerClass = objc_getClass(Self.managerClassName) as? NSObject.Type else {
            log("sidecar framework unavailable on this macOS build")
            return
        }
        self.managerClass = managerClass
        supported = Self.invokeIsSupported(managerClass)
        log("sidecar loaded supported=\(supported)")
    }

    /// The singleton is resolved on the first device question, not on the
    /// capability check: creating it starts the framework talking to Rapport,
    /// and merely advertising `sidecar` in a Bonjour record must not cost that.
    private func sharedManager() -> NSObject? {
        loadIfNeeded()
        guard supported, let managerClass else { return nil }
        if let manager { return manager }
        let shared = Self.invokeSharedManager(managerClass)
        manager = shared
        if shared == nil { log("sidecar manager unavailable") }
        return shared
    }

    private static func invokeSharedManager(_ managerClass: NSObject.Type) -> NSObject? {
        let selector = NSSelectorFromString("sharedManager")
        guard let method = class_getClassMethod(managerClass, selector) else { return nil }
        typealias SharedManagerIMP = @convention(c) (AnyObject, Selector) -> NSObject?
        let imp = unsafeBitCast(method_getImplementation(method), to: SharedManagerIMP.self)
        return imp(managerClass as AnyObject, selector)
    }

    private static func invokeIsSupported(_ managerClass: NSObject.Type) -> Bool {
        let selector = NSSelectorFromString("isSupported")
        guard let method = class_getClassMethod(managerClass, selector) else { return false }
        typealias IsSupportedIMP = @convention(c) (AnyObject, Selector) -> Bool
        let imp = unsafeBitCast(method_getImplementation(method), to: IsSupportedIMP.self)
        return imp(managerClass as AnyObject, selector)
    }

    // MARK: - Device list

    private static func readDevices(from manager: NSObject, key: String) -> [SidecarBridgeDevice] {
        deviceObjects(from: manager, key: key).compactMap { device in
            // A device without a UUID cannot be addressed, so it is not offered.
            guard let identifier = (device.value(forKey: "identifier") as? UUID)?.uuidString else { return nil }
            let model = nonEmpty(device.value(forKey: "model") as? String)
            let name = nonEmpty(device.value(forKey: "name") as? String)
            // Sidecar only ever targets iPads, so the model is a fair stand-in
            // for a name the framework withholds.
            return SidecarBridgeDevice(
                identifier: identifier,
                name: name ?? model ?? "iPad",
                model: model
            )
        }
    }

    private static func deviceObjects(from manager: NSObject, key: String) -> [NSObject] {
        guard manager.responds(to: NSSelectorFromString(key)),
              let values = manager.value(forKey: key) as? [NSObject] else { return [] }
        return values
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func deviceObject(matching identifier: String, from manager: NSObject) -> NSObject? {
        Self.deviceObjects(from: manager, key: "devices").first { device in
            (device.value(forKey: "identifier") as? UUID)?.uuidString == identifier
        }
    }

    // MARK: - Connect / disconnect

    /// `@escaping` is load-bearing, not decoration: SidecarCore answers on its
    /// own queue long after the call returns, and a block Swift believes is
    /// `@noescape` makes the runtime trap the moment the framework keeps it.
    private typealias DeviceOperationIMP = @convention(c) (
        AnyObject, Selector, AnyObject, @escaping @convention(block) (NSError?) -> Void
    ) -> Void

    private func invoke(_ selectorName: String, deviceID: String) async -> SidecarBridgeError? {
        guard supported, let manager = sharedManager() else { return .unsupported }
        guard let device = deviceObject(matching: deviceID, from: manager) else { return .deviceMissing }
        let selector = NSSelectorFromString(selectorName)
        guard let method = class_getInstanceMethod(type(of: manager), selector) else { return .unsupported }
        let imp = unsafeBitCast(method_getImplementation(method), to: DeviceOperationIMP.self)
        let gate = ResumeGate()
        log("sidecar \(selectorName) device=\(deviceID)")
        return await withCheckedContinuation { continuation in
            imp(manager, selector, device) { error in
                guard gate.consume() else { return }
                continuation.resume(returning: error.map {
                    SidecarBridgeError.refused(domain: $0.domain, code: $0.code)
                })
            }
        }
    }

    /// Resumes at most once. The completion block belongs to a private
    /// framework, and resuming a continuation twice takes the whole app down.
    private final class ResumeGate: @unchecked Sendable {
        private let lock = NSLock()
        private var isConsumed = false

        func consume() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if isConsumed { return false }
            isConsumed = true
            return true
        }
    }
}
