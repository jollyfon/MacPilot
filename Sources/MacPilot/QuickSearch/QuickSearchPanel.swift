//
//  QuickSearchPanel.swift
//  MacPilot
//
//  快速搜索的浮层：独立 NSPanel + NSHostingView。
//
//  焦点与窗口生命周期沿用 `ClipboardPanel` 的经验（非激活面板、延迟一拍再聚焦、
//  resignKey 后延迟关闭以免被菜单跟踪误杀），但不共用它的业务模型。
//
//  键盘分流是这里的关键：输入法组词（marked text）期间，Enter / Esc / 方向键
//  属于文本输入系统，不能被当成启动器的执行与导航。
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - 面板几何

enum QuickSearchPanelLayout {
    /// 默认宽度；屏幕不够宽时按可用宽度收缩。
    static let defaultWidth: CGFloat = 620
    static let minimumWidth: CGFloat = 400
    /// 行高固定：键盘导航与滚动位置才可预测。
    static let rowHeight: CGFloat = 40
    static let cornerRadius: CGFloat = 16
    /// 结果区一屏大致能放下的行数，用来算初始高度。
    static let preferredVisibleRows = 9
    static let searchFieldHeight: CGFloat = 46
    static let footerHeight: CGFloat = 34
    static let headerHeight: CGFloat = 30
}

// MARK: - 按键分流

/// 面板的显示/收起接口。模型只依赖这个协议，自动化测试才能用不显示真实窗口、
/// 不抢占用户焦点的替身来验证生命周期。
@MainActor
protocol QuickSearchPanelPresenting: AnyObject {
    var isPresented: Bool { get }
    func open()
    func close()
}

/// 一次按键应该做什么。纯函数，可脱离真实窗口验证——输入法那条规则必须能被测试覆盖。
enum QuickSearchKeyAction: Equatable {
    case openSelection
    case revealInFinder
    case closePanel
    case moveSelection(Int)
    /// 交给输入系统：文本编辑、输入法组词、Cmd+A/C/V 等原生快捷键。
    case passThrough
}

enum QuickSearchKeyRouter {
    static func action(
        keyCode: UInt16,
        commandHeld: Bool,
        controlHeld: Bool,
        isComposingText: Bool
    ) -> QuickSearchKeyAction {
        // 输入法有候选词/marked text 时，Enter、Esc、方向键都属于文本输入流程。
        guard !isComposingText else { return .passThrough }
        switch keyCode {
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
            return commandHeld ? .revealInFinder : .openSelection
        case UInt16(kVK_Escape):
            return .closePanel
        case UInt16(kVK_UpArrow) where !commandHeld && !controlHeld:
            return .moveSelection(-1)
        case UInt16(kVK_DownArrow) where !commandHeld && !controlHeld:
            return .moveSelection(1)
        default:
            return .passThrough
        }
    }
}

// MARK: - 面板

/// 不抢占前台应用焦点的搜索面板：呼出即可输入，点到别处自动收起。
final class QuickSearchPanel: NSPanel, QuickSearchPanelPresenting {
    private(set) var isPresented = false
    private let onClose: () -> Void
    private weak var model: QuickSearchModel?

    private let hostingView: NSHostingView<QuickSearchPanelContent>
    private var keyMonitor: Any?
    private var pendingResignClose: DispatchWorkItem?

    init(model: QuickSearchModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        self.hostingView = NSHostingView(rootView: QuickSearchPanelContent(model: model))

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: QuickSearchPanelLayout.defaultWidth, height: 380),
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        // 跟随当前 Space、能盖在全屏 App 上、不参与 Exposé 抖动。
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .none
        hidesOnDeactivate = false
        isMovable = false
        contentView = hostingView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: 显示与关闭

    func open() {
        pendingResignClose?.cancel()
        pendingResignClose = nil
        isPresented = true
        positionOnScreen()
        orderFrontRegardless()
        makeKey()
        installKeyMonitor()
        // 延迟一拍再设第一响应者：同步设置会被随后的 makeKey 覆盖，输入框拿不到焦点。
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isPresented else { return }
            self.makeFirstResponder(self.hostingView)
        }
    }

    override func close() {
        pendingResignClose?.cancel()
        pendingResignClose = nil
        removeKeyMonitor()
        isPresented = false
        super.close()
        onClose()
    }

    override func resignKey() {
        super.resignKey()
        guard isPresented else { return }
        // 结束菜单跟踪会让面板短暂失去 key，紧接着又被重新提上来；
        // 同步关闭会让「点了菜单项却没反应」。给它 0.1 秒确认。
        pendingResignClose?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isPresented, !self.isKeyWindow else { return }
            self.close()
        }
        pendingResignClose = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    // MARK: 多显示器定位

    private func positionOnScreen() {
        let screen = screenForPointer()
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let width = max(
            QuickSearchPanelLayout.minimumWidth,
            min(QuickSearchPanelLayout.defaultWidth, visibleFrame.width - 80)
        )
        let rowCount = min(
            CGFloat(model?.results.count ?? 0),
            CGFloat(QuickSearchPanelLayout.preferredVisibleRows)
        )
        let contentHeight = QuickSearchPanelLayout.searchFieldHeight
            + rowCount * QuickSearchPanelLayout.rowHeight
            + (rowCount > 0 ? 20 : 120)   // 结果区留白；无结果时给状态文案留出空间
            + QuickSearchPanelLayout.footerHeight
        let height = min(max(contentHeight, 180), visibleFrame.height - 80)
        setContentSize(NSSize(width: width, height: height))
        let x = visibleFrame.midX - width / 2
        // 放在指针所在屏幕的上三分之一处，和系统聚焦类面板的习惯一致。
        let y = min(visibleFrame.maxY - height - 96, visibleFrame.maxY - visibleFrame.height * 0.45)
        setFrameOrigin(NSPoint(x: x, y: max(y, visibleFrame.minY + 40)))
    }

    /// 用指针位置选屏，而不是「主屏」：多显示器下呼出应该出现在手边。
    private func screenForPointer() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    // MARK: 键盘

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event)
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    /// 返回 nil 表示事件已被消费。
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard isPresented, let model else { return event }
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
        let action = QuickSearchKeyRouter.action(
            keyCode: event.keyCode,
            commandHeld: flags.contains(.command),
            controlHeld: flags.contains(.control),
            isComposingText: isComposingText
        )
        switch action {
        case .openSelection:
            model.performPrimaryAction()
            return nil
        case .revealInFinder:
            model.revealSelectionInFinder()
            return nil
        case .closePanel:
            model.closePanel()
            return nil
        case .moveSelection(let delta):
            model.moveSelection(by: delta)
            return nil
        case .passThrough:
            // 组词中的 Enter/Esc/方向键、以及 Cmd+A / Cmd+C / Cmd+V 原样放行。
            return event
        }
    }

    /// 输入法是否正在组词（有 marked text / 候选词）。
    /// SwiftUI 的输入框最终落在窗口的字段编辑器上，它就是一个 `NSTextView`。
    private var isComposingText: Bool {
        guard let textView = firstResponder as? NSTextView else { return false }
        return textView.markedRange().location != NSNotFound
    }
}

// MARK: - 轻量失败提示

/// 失败提示的显示出口。测试注入替身，避免自动化测试在用户桌面上闪出真窗口。
@MainActor
protocol QuickSearchNoticePresenting: AnyObject {
    func present(_ text: String)
    func dismiss()
}

/// 面板关闭后的失败反馈。不复用主窗口，也不把它调出来——需求明确要求启动失败
/// 不能把 MacPilot 的设置界面拽到前台。
final class QuickSearchNoticePanel: NSPanel, QuickSearchNoticePresenting {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 44),
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .utilityWindow
        hidesOnDeactivate = false
        isMovable = false
        // 只读提示：不抢键盘焦点，否则刚关掉的搜索又把焦点从用户的 App 手里拿走。
        becomesKeyOnlyIfNeeded = true

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        label.backgroundColor = .clear

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 44))
        container.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        contentView = container
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func present(_ text: String) {
        label.stringValue = text
        guard let screen = NSScreen.screens.first(where: {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = NSSize(width: 420, height: 44)
        setContentSize(size)
        setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 72
        ))
        orderFrontRegardless()
    }

    func dismiss() {
        orderOut(nil)
    }
}
