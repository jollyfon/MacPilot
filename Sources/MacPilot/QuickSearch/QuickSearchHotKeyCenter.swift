//
//  QuickSearchHotKeyCenter.swift
//  MacPilot
//
//  快速搜索面板的全局快捷键。结构沿用 `ClipboardHotKeyCenter`（Carbon
//  `RegisterEventHotKey` + 一个回调上下文），但这里必须把注册结果说出来：
//  注册失败不能把快捷键标成「已启用」，否则用户看到的是能按、实际按不动。
//

import AppKit
import Carbon.HIToolbox
import Foundation

enum QuickSearchHotKeyError: Equatable, Sendable {
    /// 绑定本身不合法（缺少修饰键，或占用了保留键）。
    case invalidBinding
    /// Carbon 事件处理器装不上。
    case handlerInstallFailed(status: Int)
    /// `RegisterEventHotKey` 返回非 noErr。
    case registrationFailed(status: Int)
    /// 旧快捷键未能可靠注销；仍保留其 registration 以便重试清理。
    case unregistrationFailed(status: Int)
    /// 事件处理器仍待清理；快捷键当前状态请结合 `isRegistered` 判断。
    case cleanupPending(status: Int)
    /// 与 MacPilot 自己的另一个功能用了同一个组合。
    case conflictsWithOtherFeature(sectionTitleKey: String)

    var messageKey: String {
        switch self {
        case .invalidBinding: "quickSearchHotkeyInvalid"
        case .handlerInstallFailed, .registrationFailed, .unregistrationFailed: "quickSearchHotkeyRegistrationFailed"
        case .cleanupPending: "quickSearchHotkeyCleanupPending"
        case .conflictsWithOtherFeature: "quickSearchHotkeyConflict"
        }
    }

    /// 冲突提示需要把冲突对象一起说出来。
    var conflictSectionTitleKey: String? {
        if case .conflictsWithOtherFeature(let key) = self { return key }
        return nil
    }
}

struct QuickSearchHotKeyEventIdentifier: Equatable, Sendable {
    let signature: OSType
    let identifier: UInt32
}

/// 不暴露 Carbon 的不透明 registration handle；测试驱动也用同一 token contract。
struct QuickSearchHotKeyRegistrationToken: Hashable, Sendable {
    fileprivate let rawValue: UUID

    init() {
        rawValue = UUID()
    }
}

enum QuickSearchHotKeyDriverResult {
    case installed(token: QuickSearchHotKeyRegistrationToken, status: Int)
    case handlerInstallFailed(status: Int)
    case registrationFailed(status: Int, cleanupToken: QuickSearchHotKeyRegistrationToken?)
}

enum QuickSearchHotKeyUnregistrationResult: Equatable {
    case stillRegistered(status: Int)
    case keyReleased(handlerCleanupStatus: Int?)
}

@MainActor
protocol QuickSearchHotKeyDriver {
    func register(
        _ binding: SmartCaptureShortcutBinding,
        eventIdentifier: QuickSearchHotKeyEventIdentifier,
        onEvent: @escaping @MainActor () -> Void
    ) -> QuickSearchHotKeyDriverResult

    func unregister(_ token: QuickSearchHotKeyRegistrationToken) -> QuickSearchHotKeyUnregistrationResult
}

/// Shared routing disposition used by the Carbon callback and deterministic tests.
func quickSearchHotKeyEventDisposition(
    status: OSStatus,
    received: QuickSearchHotKeyEventIdentifier?,
    expected: QuickSearchHotKeyEventIdentifier
) -> OSStatus {
    guard status == noErr else { return status }
    guard let received,
          received.signature == expected.signature,
          received.identifier == expected.identifier else {
        return OSStatus(eventNotHandledErr)
    }
    return noErr
}

/// Carbon-backed implementation. Each registration owns its handler context and native refs.
@MainActor
private final class CarbonQuickSearchHotKeyDriver: QuickSearchHotKeyDriver {
    private struct Registration {
        var hotKey: EventHotKeyRef?
        var handler: EventHandlerRef?
        let contextLease: QuickSearchHotKeyContextLease
    }

    private var registrations: [QuickSearchHotKeyRegistrationToken: Registration] = [:]

    func register(
        _ binding: SmartCaptureShortcutBinding,
        eventIdentifier: QuickSearchHotKeyEventIdentifier,
        onEvent: @escaping @MainActor () -> Void
    ) -> QuickSearchHotKeyDriverResult {
        let context = QuickSearchHotKeyContext(eventIdentifier: eventIdentifier, onEvent: onEvent)
        let contextLease = QuickSearchHotKeyContextLease(context)
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var handler: EventHandlerRef?
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            quickSearchHotKeyEventHandler,
            1,
            &eventType,
            contextLease.opaquePointer,
            &handler
        )
        guard handlerStatus == noErr, let handler else {
            contextLease.release()
            return .handlerInstallFailed(status: Int(handlerStatus))
        }

        let token = QuickSearchHotKeyRegistrationToken()
        registrations[token] = Registration(hotKey: nil, handler: handler, contextLease: contextLease)
        var hotKey: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(binding.keyCode),
            quickSearchHotKeyModifiers(for: binding),
            EventHotKeyID(signature: eventIdentifier.signature, id: eventIdentifier.identifier),
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyNoOptions),
            &hotKey
        )
        guard status == noErr, let hotKey else {
            let cleanupStatus = RemoveEventHandler(handler)
            if cleanupStatus == noErr {
                contextLease.release()
                registrations[token] = nil
            } else {
                registrations[token] = Registration(hotKey: nil, handler: handler, contextLease: contextLease)
            }
            let failureStatus = status == noErr ? OSStatus(eventNotHandledErr) : status
            return .registrationFailed(
                status: Int(failureStatus),
                cleanupToken: cleanupStatus == noErr ? nil : token
            )
        }

        registrations[token] = Registration(hotKey: hotKey, handler: handler, contextLease: contextLease)
        return .installed(token: token, status: Int(status))
    }

    func unregister(_ token: QuickSearchHotKeyRegistrationToken) -> QuickSearchHotKeyUnregistrationResult {
        guard var registration = registrations[token] else { return .keyReleased(handlerCleanupStatus: nil) }
        if let hotKey = registration.hotKey {
            let status = UnregisterEventHotKey(hotKey)
            guard status == noErr else { return .stillRegistered(status: Int(status)) }
            registration.hotKey = nil
        }
        if let handler = registration.handler {
            let status = RemoveEventHandler(handler)
            guard status == noErr else {
                registrations[token] = registration
                return .keyReleased(handlerCleanupStatus: Int(status))
            }
            registration.contextLease.release()
            registration.handler = nil
        }
        registrations[token] = nil
        return .keyReleased(handlerCleanupStatus: nil)
    }
}

/// 注册并管理快速搜索面板的全局快捷键；触发时回调 `onToggle`。
@MainActor
final class QuickSearchHotKeyCenter {
    /// 与其它功能区分开：`ClipboardHotKeyCenter` 用的是 "MPCL"。
    nonisolated static let hotKeySignature: OSType = 0x4D505153 // "MPQS"
    nonisolated static let hotKeyIdentifier: UInt32 = 1

    var onToggle: (() -> Void)?
    /// 由模型注入：检查这个组合是否已被 MacPilot 内的其它功能占用。
    var conflictChecker: (@MainActor (SmartCaptureShortcutBinding) -> String?)?

    private(set) var registeredBinding: SmartCaptureShortcutBinding?
    private(set) var lastError: QuickSearchHotKeyError?
    /// 供设置页与诊断读取：注册状态码原样保留，方便排查。
    private(set) var lastRegistrationStatus: Int?

    private let driver: any QuickSearchHotKeyDriver
    private var registrationToken: QuickSearchHotKeyRegistrationToken?
    private var pendingCleanupTokens: [QuickSearchHotKeyRegistrationToken] = []
    /// Pending contexts may still own a native key if Carbon refused to unregister it.
    private var pendingHotKeyTokens: Set<QuickSearchHotKeyRegistrationToken> = []
    private var registrationEventIdentifier: QuickSearchHotKeyEventIdentifier?
    private var callbacksEnabled = false
    private static var nextEventIdentifier = hotKeyIdentifier

    init(driver: any QuickSearchHotKeyDriver = CarbonQuickSearchHotKeyDriver()) {
        self.driver = driver
    }

    /// 确保快捷键按 `binding` 注册。返回 nil 表示已注册成功，否则给出原因。
    /// 注册失败时保留仍工作的旧绑定；只有新绑定确认成功且旧绑定已注销后才切换。
    @discardableResult
    func updateBinding(_ binding: SmartCaptureShortcutBinding) -> QuickSearchHotKeyError? {
        if let error = validate(binding) {
            lastError = error
            return error
        }
        let pendingCleanupError = cleanPendingRegistrations()
        if case .unregistrationFailed? = pendingCleanupError {
            lastError = pendingCleanupError
            return pendingCleanupError
        }
        if registeredBinding == binding, registrationToken != nil {
            callbacksEnabled = true
            lastRegistrationStatus = Int(noErr)
            lastError = pendingCleanupError
            return nil
        }
        let eventIdentifier = QuickSearchHotKeyEventIdentifier(
            signature: Self.hotKeySignature,
            identifier: Self.allocateEventIdentifier()
        )
        let result = driver.register(binding, eventIdentifier: eventIdentifier) { [weak self] in
            guard let self,
                  self.callbacksEnabled,
                  self.registrationEventIdentifier == eventIdentifier else { return }
            self.onToggle?()
        }
        switch result {
        case .installed(let token, let status):
            var cleanupWarning: QuickSearchHotKeyError?
            if case .cleanupPending? = pendingCleanupError {
                cleanupWarning = pendingCleanupError
            }
            if let oldToken = registrationToken {
                switch driver.unregister(oldToken) {
                case .stillRegistered(let unregistrationStatus):
                    let rollbackResult = driver.unregister(token)
                    switch rollbackResult {
                    case .stillRegistered:
                        pendingCleanupTokens.append(token)
                        pendingHotKeyTokens.insert(token)
                    case .keyReleased(let cleanupStatus):
                        if cleanupStatus != nil { pendingCleanupTokens.append(token) }
                    }
                    lastRegistrationStatus = unregistrationStatus
                    let error = QuickSearchHotKeyError.unregistrationFailed(status: unregistrationStatus)
                    lastError = error
                    return error
                case .keyReleased(let cleanupStatus):
                    if let cleanupStatus {
                        pendingCleanupTokens.append(oldToken)
                        cleanupWarning = .cleanupPending(status: cleanupStatus)
                    }
                }
            }
            registrationToken = token
            registeredBinding = binding
            registrationEventIdentifier = eventIdentifier
            callbacksEnabled = true
            lastRegistrationStatus = status
            lastError = cleanupWarning
            return nil
        case .handlerInstallFailed(let status):
            lastRegistrationStatus = status
            let error = QuickSearchHotKeyError.handlerInstallFailed(status: status)
            lastError = error
            return error
        case .registrationFailed(let status, let cleanupToken):
            if let cleanupToken { pendingCleanupTokens.append(cleanupToken) }
            lastRegistrationStatus = status
            let error = QuickSearchHotKeyError.registrationFailed(status: status)
            lastError = error
            return error
        }
    }

    /// 注销快捷键。功能停用/退出时同步调用。
    func stop() {
        callbacksEnabled = false
        var failureStatus: Int?
        var cleanupStatus: Int?
        if let pendingError = cleanPendingRegistrations() {
            switch pendingError {
            case .unregistrationFailed(let status): failureStatus = status
            case .cleanupPending(let status): cleanupStatus = status
            default: break
            }
        }
        if let registrationToken {
            switch driver.unregister(registrationToken) {
            case .stillRegistered(let status):
                failureStatus = failureStatus ?? status
            case .keyReleased(let handlerCleanupStatus):
                self.registrationToken = nil
                registeredBinding = nil
                registrationEventIdentifier = nil
                if let handlerCleanupStatus {
                    pendingCleanupTokens.append(registrationToken)
                    cleanupStatus = cleanupStatus ?? handlerCleanupStatus
                }
            }
        }
        if let failureStatus {
            lastRegistrationStatus = failureStatus
            lastError = .unregistrationFailed(status: failureStatus)
        } else if let cleanupStatus {
            lastRegistrationStatus = cleanupStatus
            lastError = .cleanupPending(status: cleanupStatus)
        } else {
            lastRegistrationStatus = nil
            lastError = nil
        }
    }

    var isRegistered: Bool { registrationToken != nil }
    var hasOutstandingRegistrations: Bool { registrationToken != nil || !pendingCleanupTokens.isEmpty }
    var hasUnreleasedHotKeys: Bool { registrationToken != nil || !pendingHotKeyTokens.isEmpty }

    private func validate(_ binding: SmartCaptureShortcutBinding) -> QuickSearchHotKeyError? {
        guard binding.isValid else { return .invalidBinding }
        if let conflicting = conflictChecker?(binding) {
            return .conflictsWithOtherFeature(sectionTitleKey: conflicting)
        }
        return nil
    }

    private func cleanPendingRegistrations() -> QuickSearchHotKeyError? {
        var remaining: [QuickSearchHotKeyRegistrationToken] = []
        var firstHotKeyFailure: Int?
        var firstCleanupFailure: Int?
        for token in pendingCleanupTokens {
            switch driver.unregister(token) {
            case .stillRegistered(let status):
                remaining.append(token)
                pendingHotKeyTokens.insert(token)
                firstHotKeyFailure = firstHotKeyFailure ?? status
            case .keyReleased(let cleanupStatus):
                pendingHotKeyTokens.remove(token)
                if let cleanupStatus {
                    remaining.append(token)
                    firstCleanupFailure = firstCleanupFailure ?? cleanupStatus
                }
            }
        }
        pendingCleanupTokens = remaining
        if let firstHotKeyFailure {
            lastRegistrationStatus = firstHotKeyFailure
            return .unregistrationFailed(status: firstHotKeyFailure)
        }
        if let firstCleanupFailure {
            lastRegistrationStatus = firstCleanupFailure
            return .cleanupPending(status: firstCleanupFailure)
        }
        return nil
    }

    private static func allocateEventIdentifier() -> UInt32 {
        let identifier = nextEventIdentifier
        nextEventIdentifier = identifier == UInt32.max ? hotKeyIdentifier : identifier + 1
        return identifier
    }
}

final class QuickSearchHotKeyContext: @unchecked Sendable {
    let eventIdentifier: QuickSearchHotKeyEventIdentifier
    let onEvent: @MainActor () -> Void

    init(
        eventIdentifier: QuickSearchHotKeyEventIdentifier,
        onEvent: @escaping @MainActor () -> Void
    ) {
        self.eventIdentifier = eventIdentifier
        self.onEvent = onEvent
    }
}

/// Holds the C callback's userData alive until Carbon confirms handler removal. If the
/// driver goes away while Carbon still owns the handler, the unmanaged retain is
/// intentionally left in place so a late callback cannot dereference freed memory.
@MainActor
final class QuickSearchHotKeyContextLease {
    private(set) var context: QuickSearchHotKeyContext?
    private(set) var opaquePointer: UnsafeMutableRawPointer?

    init(_ context: QuickSearchHotKeyContext) {
        self.context = context
        opaquePointer = Unmanaged.passRetained(context).toOpaque()
    }

    func release() {
        guard let opaquePointer else { return }
        self.opaquePointer = nil
        context = nil
        Unmanaged<QuickSearchHotKeyContext>.fromOpaque(opaquePointer).release()
    }
}

private func quickSearchHotKeyModifiers(for binding: SmartCaptureShortcutBinding) -> UInt32 {
    var result: UInt32 = 0
    if binding.modifiers.contains(.command) { result |= UInt32(cmdKey) }
    if binding.modifiers.contains(.option) { result |= UInt32(optionKey) }
    if binding.modifiers.contains(.control) { result |= UInt32(controlKey) }
    if binding.modifiers.contains(.shift) { result |= UInt32(shiftKey) }
    return result
}

private func quickSearchHotKeyEventHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    let context = Unmanaged<QuickSearchHotKeyContext>.fromOpaque(userData).takeUnretainedValue()
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    let received = status == noErr
        ? QuickSearchHotKeyEventIdentifier(signature: hotKeyID.signature, identifier: hotKeyID.id)
        : nil
    let disposition = quickSearchHotKeyEventDisposition(
        status: status,
        received: received,
        expected: context.eventIdentifier
    )
    guard disposition == noErr, received == context.eventIdentifier else { return disposition }
    Task { @MainActor in context.onEvent() }
    return noErr
}
