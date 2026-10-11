//
//  QuickSearchView.swift
//  MacPilot
//
//  快速搜索面板的内容视图：顶部输入框 + 应用与文件混排的结果列表。
//
//  三件事在这里说清楚：
//  1. 每行标出分类，应用和文件不会看着像同一种东西；
//  2. 空查询展示最近使用的应用，而不是一个空白框；
//  3. 「查不了」和「没有结果」是两句话——Spotlight 不可用时必须说原因。
//
//  行高固定、懒加载：只有滚到可见范围的行才会去取图标。
//

import AppKit
import SwiftUI

// MARK: - 面板内容

struct QuickSearchPanelContent: View {
    @ObservedObject var model: QuickSearchModel
    @ObservedObject private var icons: QuickSearchIconLoader
    @FocusState private var inputIsFocused: Bool

    init(model: QuickSearchModel) {
        self.model = model
        self._icons = ObservedObject(wrappedValue: model.icons)
    }

    var body: some View {
        VStack(spacing: 0) {
            inputRow
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            resultsArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 9)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: QuickSearchPanelLayout.cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.18), radius: 22, y: 8)
        }
        .overlay {
            RoundedRectangle(cornerRadius: QuickSearchPanelLayout.cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        }
        .ignoresSafeArea(.container)
        // 面板是即时出现的浮层：任何布局变化都不该变成整个面板的入场动画。
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        .onAppear {
            // 延迟一拍：宿主视图被设为 first responder 之后，焦点才能真正落到输入框。
            DispatchQueue.main.async { inputIsFocused = true }
        }
    }

    // MARK: 输入行

    private var inputRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(
                model.t("quickSearchPlaceholder"),
                text: Binding(
                    get: { model.query },
                    set: { model.updateQuery($0) }
                )
            )
            .textFieldStyle(.plain)
            .font(.system(size: 15))
            .focused($inputIsFocused)
            // 输入法组词由 AppKit 的字段编辑器接管，这里不拦截任何按键。
            .submitLabel(.done)

            if isSearching {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
            } else if !model.query.isEmpty {
                Button {
                    model.updateQuery("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.t("quickSearchClearQuery"))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: QuickSearchPanelLayout.searchFieldHeight - 8)
        .background(
            Color.primary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.primary.opacity(0.07))
        )
    }

    private var isSearching: Bool {
        model.searchPhase != .idle
    }

    // MARK: 结果区

    @ViewBuilder
    private var resultsArea: some View {
        if model.results.isEmpty {
            stateMessage
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                            QuickSearchResultRow(
                                result: result,
                                icon: icons.icon(
                                    for: result.url,
                                    pointSize: 24,
                                    key: result.iconKey
                                ),
                                isSelected: index == model.selectedRowIndex,
                                categoryLabel: model.t(result.categoryKey)
                            ) {
                                model.selectRow(at: index)
                            } onActivate: {
                                model.performPrimaryAction(on: result)
                            }
                            .id(result.id)
                            .padding(.horizontal, 8)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .scrollContentBackground(.hidden)
                .onChange(of: model.selectedRowIndex) { _, index in
                    guard model.results.indices.contains(index) else { return }
                    proxy.scrollTo(model.results[index].id, anchor: .center)
                }
            }
        }
    }

    /// 空结果时到底说什么：索引不可用 ≠ 没有这个文件。
    @ViewBuilder
    private var stateMessage: some View {
        VStack(spacing: 8) {
            if let issue = model.fileSearchIssue {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.orange)
                Text(model.t(issue.messageKey))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if isSearching {
                ProgressView()
                    .controlSize(.small)
                Text(model.t("quickSearchSearching"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(model.t("quickSearchRecentEmpty"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                Image(systemName: "questionmark.folder")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(model.t("quickSearchNoResults", model.query))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 22)
    }

    // MARK: 底部提示
    //
    // 键帽视图沿用剪贴板面板已有的 `ClipboardKeyCap` / `ClipboardKeyHint`：
    // 它们是纯粹的展示组件，与本模块共用可以避免同一套浮层出现两份排版。
    private var footer: some View {
        HStack(spacing: 9) {
            ClipboardKeyHint(keys: "↑↓", label: model.t("quickSearchHintSelect"))
            ClipboardKeyHint(keys: "⏎", label: model.t("quickSearchHintOpen"))
            ClipboardKeyHint(keys: "⌘⏎", label: model.t("quickSearchHintReveal"))
            ClipboardKeyHint(keys: "⎋", label: model.t("quickSearchHintClose"))
            Spacer(minLength: 4)
            if model.inventory.state == .building {
                Text(model.t("quickSearchIndexBuilding"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - 结果行

private struct QuickSearchResultRow: View {
    let result: QuickSearchResult
    let icon: NSImage?
    let isSelected: Bool
    let categoryLabel: String
    let onSelect: () -> Void
    let onActivate: () -> Void

    var body: some View {
        Button(action: onActivate) {
            HStack(spacing: 9) {
                iconSlot
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(result.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(categoryLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isSelected ? Color(nsColor: .controlAccentColor) : Color.secondary.opacity(0.7))
                    .padding(.horizontal, 6)
                    .frame(height: 16)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(isSelected
                                  ? Color(nsColor: .controlAccentColor).opacity(0.16)
                                  : Color.primary.opacity(0.06))
                    )
            }
            .padding(.horizontal, 9)
            .frame(height: QuickSearchPanelLayout.rowHeight)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .background(rowBackground)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            // 指针划过即选中：Enter 就能直接打开，不需要先点一下。
            if hovering { onSelect() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// 图标还没到达时先占位，异步取图完成后由 revision 合并刷新。
    @ViewBuilder
    private var iconSlot: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
        } else {
            Image(systemName: result.categorySymbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(isSelected
                  ? Color(nsColor: .controlAccentColor).opacity(0.22)
                  : Color.primary.opacity(0.045))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color(nsColor: .controlAccentColor).opacity(0.55), lineWidth: 1)
                }
            }
    }
}
