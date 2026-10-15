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

    init(model: QuickSearchModel) {
        self.model = model
        self._icons = ObservedObject(wrappedValue: model.icons)
    }

    var body: some View {
        VStack(spacing: 0) {
            dragHeader

            inputRow
                .padding(.horizontal, 12)
                .padding(.top, 4)
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
    }

    // MARK: 顶栏抓手

    /// 拖动面。SwiftUI 的内容不会可靠地把「可移动背景」上的鼠标事件透传给
    /// `NSHostingView`，所以这块交给一个明确的 AppKit 视图（与剪贴板面板同一做法）。
    /// 记住过位置时右侧给一个「回到默认位置」，不靠隐藏手势。
    private var dragHeader: some View {
        ZStack {
            QuickSearchPanelDragHandle()
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.quaternary)
            HStack(spacing: 0) {
                Spacer()
                if model.panelPosition != nil {
                    Button {
                        model.resetPanelPosition()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(model.t("quickSearchResetPosition"))
                }
            }
            .padding(.trailing, 8)
        }
        .frame(height: QuickSearchPanelLayout.headerHeight)
        .help(model.t("quickSearchDragHint"))
    }

    // MARK: 输入行

    private var inputRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            QuickSearchQueryField(model: model)
                .frame(maxWidth: .infinity)

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
                        let favoriteLabel = model.t("quickSearchFavoriteMark")
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                            QuickSearchResultRow(
                                result: result,
                                icon: icons.icon(
                                    for: result.url,
                                    pointSize: 24,
                                    key: result.iconKey
                                ),
                                isSelected: index == model.selectedRowIndex,
                                isFavorite: model.favoriteIdentities.contains(result.favoriteIdentity),
                                favoriteLabel: favoriteLabel,
                                categoryLabel: model.t(result.categoryKey),
                                // 用途命中没有名称上的理由可说，就把命中的标签放到
                                // 本来表示类别的那枚标签上：这一条为什么出现，一眼看得见。
                                purposeLabel: result.matchedTagTerms.first
                            ) {
                                model.selectRow(at: index)
                            } onActivate: {
                                model.performPrimaryAction(on: result)
                            }
                            .id(result.id)
                            .padding(.horizontal, 8)
                            // 右键菜单作用在这一行上，动作也直接带着这一条结果：
                            // 指针划过会把选中行挪到右键处，但菜单不能因此打到别的条目。
                            .contextMenu {
                                Button(model.t("quickSearchHintOpen")) {
                                    model.performPrimaryAction(on: result)
                                }
                                Button(model.t("quickSearchHintReveal")) {
                                    model.revealSelectionInFinder(on: result)
                                }
                                Divider()
                                Button(
                                    model.t(model.isFavorite(result)
                                            ? "quickSearchMenuRemoveFavorite"
                                            : "quickSearchMenuAddFavorite")
                                ) {
                                    model.toggleFavorite(result)
                                }
                            }
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

// MARK: - 拖动面

private struct QuickSearchPanelDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragHandleView { DragHandleView() }
    func updateNSView(_ nsView: DragHandleView, context: Context) {}

    final class DragHandleView: NSView {
        override var acceptsFirstResponder: Bool { false }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func mouseDown(with event: NSEvent) {
            (window as? QuickSearchPanel)?.dragFromHeader(with: event)
        }
    }
}

// MARK: - 结果行

private struct QuickSearchResultRow: View {
    let result: QuickSearchResult
    let icon: NSImage?
    let isSelected: Bool
    let isFavorite: Bool
    let favoriteLabel: String
    let categoryLabel: String
    /// 用途标签命中时显示在类别位置上的词（「下载」「图片」）；名称命中为 nil。
    let purposeLabel: String?
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
                // 收藏只用一枚星标说明，不占分类标签的位置：加表头会把
                // 固定行高与键盘下标的对应关系打散。
                if isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .systemYellow))
                        .accessibilityLabel(favoriteLabel)
                }
                Text(purposeLabel ?? categoryLabel)
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
