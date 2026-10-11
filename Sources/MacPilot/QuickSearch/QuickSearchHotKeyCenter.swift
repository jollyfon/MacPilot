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
    /// 与 MacPilot 自己的另一个功能用了同一个组合。
    case conflictsWithOtherFeature(sectionTitleKey: String)

    var messageKey: String {
        switch self {
        case .invalidBinding: "quickSearchHotkeyInvalid"
        case .handlerInstallFailed, .registrationFailed: "quickSearchHotkeyRegistrationFailed"
        case .conflictsWithOtherFeature: "quickSearchHotkeyConflict"
        }
    }

    /// 冲突提示需要把冲突对象一起说出来。
    var conflictSectionTitleKey: String? {
        if case .conflictsWithOtherFeature(let key) = self { return key }
        return nil
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

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var context: QuickSearchHotKeyContext?

    /// 确保快捷键按 `binding` 注册。返回 nil 表示已注册成功，否则给出原因。
    /// 注册失败时保持注销状态，绝不留下「界面显示已启用、实际没注册」的假状态。
    @discardableResult
    func updateBinding(_ binding: SmartCaptureShortcutBinding) -> QuickSearchHotKeyError? {
        if let error = validate(binding) {
            unregister()
            lastError = error
            return error
        }
        guard registeredBinding != binding || hotKeyRef == nil else {
            lastError = nil
            return nil
        }
        unregister()
        let error = install(binding)
        lastError = error
        return error
    }

    /// 注销快捷键。功能停用/退出时同步调用。
    func stop() {
        unregister()
        lastError = nil
    }

    var isRegistered: Bool { hotKeyRef != nil }

    private func validate(_ binding: SmartCaptureShortcutBinding) -> QuickSearchHotKeyError? {
        guard binding.isValid else { return .invalidBinding }
        if let conflicting = conflictChecker?(binding) {
            return .conflictsWithOtherFeature(sectionTitleKey: conflicting)
        }
        return nil
    }

    private func install(_ binding: SmartCaptureShortcutBinding) -> QuickSearchHotKeyError? {
        let context = QuickSearchHotKeyContext(onToggle: { [weak self] in self?.onToggle?() })
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
            Unmanaged.passUnretained(context).toOpaque(),
            &handler
        )
        lastRegistrationStatus = Int(handlerStatus)
        guard handlerStatus == noErr, let handler else {
            return .handlerInstallFailed(status: Int(handlerStatus))
        }

        var hotKey: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(binding.keyCode),
            Self.hotKeyModifiers(for: binding),
            EventHotKeyID(signature: Self.hotKeySignature, id: Self.hotKeyIdentifier),
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyNoOptions),
            &hotKey
        )
        lastRegistrationStatus = Int(status)
        guard status == noErr, let hotKey else {
            // 回滚处理器，不留半个注册状态。
            RemoveEventHandler(handler)
            return .registrationFailed(status: Int(status))
        }

        self.context = context
        eventHandler = handler
        hotKeyRef = hotKey
        registeredBinding = binding
        return nil
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        hotKeyRef = nil
        eventHandler = nil
        context = nil
        registeredBinding = nil
        lastRegistrationStatus = nil
    }

    private static func hotKeyModifiers(for binding: SmartCaptureShortcutBinding) -> UInt32 {
        var result: UInt32 = 0
        if binding.modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if binding.modifiers.contains(.option) { result |= UInt32(optionKey) }
        if binding.modifiers.contains(.control) { result |= UInt32(controlKey) }
        if binding.modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}

@MainActor
private final class QuickSearchHotKeyContext {
    let onToggle: () -> Void
    init(onToggle: @escaping () -> Void) { self.onToggle = onToggle }
}

private func quickSearchHotKeyEventHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return noErr }
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
    guard status == noErr,
          hotKeyID.signature == QuickSearchHotKeyCenter.hotKeySignature,
          hotKeyID.id == QuickSearchHotKeyCenter.hotKeyIdentifier else {
        return status == noErr ? noErr : status
    }
    Task { @MainActor in context.onToggle() }
    return noErr
}
