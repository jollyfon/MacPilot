//
//  QuickSearchSettingsView.swift
//  MacPilot
//
//  快速搜索的设置页。遵循 docs/UI_DESIGN.md：原生侧边栏 + 30pt 标题 + 自适应玻璃
//  `SettingsCard`，卡片间距 24，页边距 36/34/30。
//
//  功能总开关在首页，这里不重复放一个开关。
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

struct QuickSearchSettingsView: View {
    @ObservedObject var quickSearch: QuickSearchModel
    @EnvironmentObject private var model: MacPilotModel
    @State private var isChoosingDirectory = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.t("quickSearch")).font(.system(size: 30, weight: .bold))
                    Text(model.t("quickSearchSubtitle")).foregroundStyle(.secondary)
                }

                runtimeCard
                panelCard
                hotkeyCard
                matchScopeCard
                fileScopeCard
            }
            .padding(.horizontal, 36)
            .padding(.top, 34)
            .padding(.bottom, 30)
        }
        .fileImporter(
            isPresented: $isChoosingDirectory,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            quickSearch.addCustomDirectory(path: url.standardizedFileURL.path)
        }
    }

    // MARK: 运行状态

    private var runtimeCard: some View {
        SettingsCard {
            HStack(spacing: 10) {
                Circle()
                    .fill(quickSearch.isRunning ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(model.t(stateKey(quickSearch.lifecycleState)))
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button {
                    quickSearch.openPanel()
                } label: {
                    Label(model.t("quickSearchOpenNow"), systemImage: "magnifyingglass")
                }
                .macPilotProminentButtonStyle()
                .disabled(!quickSearch.isRunning)
            }

            Divider()

            HStack {
                Text(model.t("quickSearchIndexCount", quickSearch.indexEntryCount))
                    .font(.subheadline)
                Spacer()
                Button(model.t("quickSearchRefreshIndex")) {
                    quickSearch.refreshApplicationIndex()
                    quickSearch.publishIndexState()
                }
                .disabled(!quickSearch.isRunning)
            }

            if let issue = quickSearch.fileSearchIssue {
                InlineHint(text: model.t(issue.messageKey))
            }
        }
    }

    // MARK: 面板位置与收藏

    private var panelCard: some View {
        SettingsCard {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.t("quickSearchPanelPositionTitle"))
                        .font(.subheadline.weight(.medium))
                    Text(model.t("quickSearchDragHint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button(model.t("quickSearchResetPosition")) {
                    quickSearch.resetPanelPosition()
                }
                // 没拖过就没有「记住的位置」可清，按钮这时候说出来的是假可点。
                .disabled(quickSearch.panelPosition == nil)
            }

            Divider()

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.t("quickSearchFavoritesTitle"))
                        .font(.subheadline.weight(.medium))
                    Text(model.t("quickSearchEmptyHint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Text(model.t("quickSearchFavoriteCount", quickSearch.settings.favorites.count))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 快捷键

    private var hotkeyCard: some View {
        SettingsCard {
            HStack(spacing: 12) {
                Text(model.t("quickSearchHotkey"))
                    .font(.subheadline)
                Spacer()
                QuickSearchHotkeyRecorder(
                    binding: Binding(
                        get: { quickSearch.settings.hotkey },
                        set: { quickSearch.setHotkey($0) }
                    ),
                    help: model.t("quickSearchHotkeyRecord")
                )
            }

            // 注册失败必须说出来：界面上写着快捷键、实际按下去没反应，是最糟的假状态。
            if let error = quickSearch.hotKeyError {
                InlineHint(text: hotkeyErrorText(error))
            } else if quickSearch.isRunning {
                InlineHint(text: quickSearch.isHotKeyRegistered
                    ? model.t("quickSearchHotkeyActive", quickSearch.settings.hotkey.displayName)
                    : model.t("quickSearchHotkeyInactive"))
            }
        }
    }

    private func hotkeyErrorText(_ error: QuickSearchHotKeyError) -> String {
        switch error {
        case .invalidBinding:
            return model.t(error.messageKey)
        case .handlerInstallFailed(let status), .registrationFailed(let status), .unregistrationFailed(let status), .cleanupPending(let status):
            return model.t(error.messageKey, status)
        case .conflictsWithOtherFeature(let conflictingTitleKey):
            return model.t(error.messageKey, model.t(conflictingTitleKey))
        }
    }

    // MARK: 匹配范围

    private var matchScopeCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.t("quickSearchMatchScopeTitle"))
                    .font(.subheadline.weight(.medium))
                Picker(model.t("quickSearchMatchScopeTitle"), selection: Binding(
                    get: { quickSearch.settings.matchScope },
                    set: { quickSearch.setMatchScope($0) }
                )) {
                    ForEach(QuickSearchMatchScope.allCases) { scope in
                        Text(model.t(scope.titleKey)).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(model.t("quickSearchMatchScopeHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 文件搜索范围

    private var fileScopeCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.t("quickSearchFileSearchTitle"))
                    .font(.subheadline.weight(.medium))
                Picker(model.t("quickSearchFileSearchTitle"), selection: Binding(
                    get: { quickSearch.settings.fileScope },
                    set: { quickSearch.setFileScope($0) }
                )) {
                    ForEach(QuickSearchFileScope.allCases) { scope in
                        Text(model.t(scope.titleKey)).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(model.t("quickSearchScopeHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if quickSearch.settings.fileScope == .indexedDirectories {
                Divider()
                customDirectories
            }
        }
    }

    private var customDirectories: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.t("quickSearchCustomDirectoriesTitle"))
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button(model.t("quickSearchAddDirectory")) {
                    isChoosingDirectory = true
                }
                .disabled(quickSearch.settings.customDirectoryPaths.count >= QuickSearchLimits.customDirectories)
            }

            if quickSearch.settings.customDirectoryPaths.isEmpty {
                Text(model.t("quickSearchNoCustomDirectories"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(quickSearch.settings.customDirectoryPaths, id: \.self) { path in
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(path)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(model.t("quickSearchRemoveDirectory")) {
                            quickSearch.removeCustomDirectory(path: path)
                        }
                    }
                }
            }

            Text(model.t("quickSearchCustomDirectoriesLimit", QuickSearchLimits.customDirectories))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func stateKey(_ state: QuickSearchModel.LifecycleState) -> String {
        switch state {
        case .disabled: "quickSearchStatusDisabled"
        case .starting: "quickSearchStatusStarting"
        case .ready: "quickSearchStatusReady"
        case .presenting: "quickSearchStatusPresenting"
        case .searching: "quickSearchStatusSearching"
        case .stopping: "quickSearchStatusStopping"
        }
    }
}

// MARK: - 行内提示

/// 设置页的橙色行内提示，与截图、录屏等页面的失败提示保持一致。
private struct InlineHint: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 快捷键录入

/// 纯 SwiftUI 的快捷键录入控件。录制期间用 `NSEvent` 局部监听，而不是
/// `NSViewRepresentable`：这样在磨砂玻璃 `SettingsCard` 的滚动视图里也能正常绘制。
///
/// 与剪贴板页的同名控件保持一致的外观。那边的是 `private`，所以这里只能另写一份，
/// 而不是共用一个「快捷键录入」组件把两个功能耦在一起。
private struct QuickSearchHotkeyRecorder: View {
    @Binding var binding: SmartCaptureShortcutBinding
    var help: String = ""
    @State private var isRecording = false
    @State private var eventMonitor: Any?

    private var displayText: String {
        if isRecording { return "…" }
        return binding.displayName.isEmpty ? "…" : binding.displayName
    }

    var body: some View {
        Button {
            isRecording = true
            installMonitor()
        } label: {
            Text(displayText)
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(isRecording ? Color.accentColor : .primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    isRecording
                        ? AnyShapeStyle(Color.accentColor.opacity(0.12))
                        : AnyShapeStyle(.quaternary),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isRecording ? Color.accentColor : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .onDisappear(perform: removeMonitor)
    }

    private func installMonitor() {
        removeMonitor()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifierKeyCodes: Set<UInt16> = [
                UInt16(kVK_Shift), UInt16(kVK_RightShift), UInt16(kVK_Control), UInt16(kVK_RightControl),
                UInt16(kVK_Option), UInt16(kVK_RightOption), UInt16(kVK_Command), UInt16(kVK_RightCommand),
                UInt16(kVK_CapsLock), UInt16(kVK_Function)
            ]
            guard !modifierKeyCodes.contains(event.keyCode) else { return nil }
            // Esc 只是取消录入：原绑定一个字节都没动过。
            if event.keyCode == UInt16(kVK_Escape) {
                isRecording = false
                removeMonitor()
                return nil
            }
            let candidate = SmartCaptureShortcutBinding(
                keyCode: event.keyCode,
                modifiers: InputSourceShortcutModifiers(event.modifierFlags)
            )
            // 无效组合不落盘：保留用户原本可用的设置，而不是悄悄改掉它。
            guard candidate.isValid else { return nil }
            binding = candidate
            isRecording = false
            removeMonitor()
            return nil
        }
    }

    private func removeMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
    }
}
