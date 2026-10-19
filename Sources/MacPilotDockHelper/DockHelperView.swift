//
//  DockHelperView.swift
//  MacPilotDockHelper
//
//  需求第 7、8、9 节：轻量浮层内容。
//  Grid / List 两种布局、运行状态圆点、键盘导航、深色模式适配。
//  刻意保持简单——这不是 MacPilot 主界面的缩小版。
//
//  性能：视图只读 `model.entries` 里已经算好的东西（名字、图标、运行状态），
//  自己不取图标。图标还没到位的那些格子画一个中性占位方块，
//  于是「浮层先出现、图标随后补」对用户是连续可见的，而不是先白屏两秒。
//

import AppKit
import MacPilotDockGroupsCore
import SwiftUI

struct DockHelperView: View {
    @ObservedObject var model: DockHelperModel
    @FocusState private var focusedIndex: Int?
    /// 拖拽中的 App 当前悬停在哪一格（只影响视觉反馈）。
    @State private var dropTargetID: UUID?

    /// 拖拽载荷前缀：只接受本浮层发出的拖拽，外部普通文本不会被当成排序指令。
    private static let dragPrefix = "dockgroup-app:"

    var body: some View {
        VStack(alignment: .leading, spacing: DockHelperLayout.sectionSpacing) {
            header
            content
        }
        .padding(DockHelperLayout.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DockHelperLayout.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DockHelperLayout.cornerRadius, style: .continuous)
                .strokeBorder(.primary.opacity(0.10))
        )
        .onAppear { focusedIndex = model.entries.isEmpty ? nil : 0 }
    }

    // MARK: - 页头

    /// 只有标题 + 设置齿轮 + 添加按钮：分组图标在这里没有信息量（点开的就是这个分组）。
    /// 启动失败的提示占用标题右侧的空白，不再单独占一行页脚——页脚那句话和它上面的
    /// 分隔线都是多余的噪声，去掉之后浮层高度也少了一整行。
    private var header: some View {
        HStack(spacing: 6) {
            Text(model.groupName)
                .font(.headline)
                .lineLimit(1)

            Button {
                model.openMacPilotSettings()
            } label: {
                // 只放图标：设置从页脚挪到标题旁，语义交给下面的 accessibilityLabel。
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help(model.t("settings"))
            .accessibilityLabel(model.t("settings"))
            .keyboardShortcut(",", modifiers: .command)

            Button {
                model.chooseAppsToAdd()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help(model.t("addApps"))
            .accessibilityLabel(model.t("addApps"))
            .disabled(model.group == nil)

            Spacer(minLength: 8)

            if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
            }
        }
        .frame(height: DockHelperLayout.headerHeight, alignment: .leading)
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if model.group == nil {
            missingGroupState
        } else if model.entries.isEmpty {
            emptyState
        } else if model.group?.layout == .list {
            listLayout
        } else {
            gridLayout
        }
    }

    private var missingGroupState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(model.t("groupMissing"), systemImage: "questionmark.folder")
                .font(.subheadline)
            Text(model.t("groupMissingHint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(model.t("emptyGroup"), systemImage: "square.dashed")
                .font(.subheadline)
            Text(model.t("emptyGroupHint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var columns: Int {
        model.group.map { DockHelperLayout.columns(for: $0) } ?? DockGroupGridMetrics.minimumColumns
    }

    private var gridLayout: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.fixed(DockHelperLayout.gridCellWidth), spacing: DockHelperLayout.gap),
                count: columns
            ),
            spacing: 6
        ) {
            ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                appCell(entry, index: index)
            }
        }
    }

    private var listLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                appRow(entry, index: index)
            }
        }
    }

    // MARK: - 单元格

    private func appCell(_ entry: DockHelperModel.Entry, index: Int) -> some View {
        Button {
            model.open(entry)
        } label: {
            VStack(spacing: 4) {
                appIcon(entry, side: 46)
                Text(entry.displayName)
                    .font(.caption2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(entry.isMissing ? .secondary : .primary)
                    .frame(maxWidth: .infinity)
            }
            .frame(width: DockHelperLayout.gridCellWidth, height: DockHelperLayout.gridRowHeight - 4, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focusedIndex, equals: index)
        .onKeyPress(.rightArrow) { moveFocus(to: index + 1) }
        .onKeyPress(.leftArrow) { moveFocus(to: index - 1) }
        .onKeyPress(.downArrow) { moveFocus(to: index + columns) }
        .onKeyPress(.upArrow) { moveFocus(to: index - columns) }
        .help(entry.isMissing ? model.t("appMissing") : entry.displayName)
        .accessibilityLabel(entry.isMissing ? "\(entry.displayName) — \(model.t("appMissing"))" : entry.displayName)
        .accessibilityValue(entry.isRunning ? model.t("running") : model.t("notRunning"))
        .contextMenu {
            Button(role: .destructive) {
                model.removeApp(entry)
            } label: {
                Label(model.t("removeFromGroup"), systemImage: "minus.circle")
            }
        }
        .draggable(Self.dragPrefix + entry.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            drop(items, onto: entry.id)
        } isTargeted: { targeted in
            updateDropTarget(targeted, id: entry.id)
        }
        .opacity(dropTargetID == entry.id ? 0.65 : 1)
    }

    private func appRow(_ entry: DockHelperModel.Entry, index: Int) -> some View {
        Button {
            model.open(entry)
        } label: {
            HStack(spacing: 10) {
                appIcon(entry, side: 22)
                Text(entry.displayName)
                    .font(.subheadline)
                    .lineLimit(1)
                    .foregroundStyle(entry.isMissing ? .secondary : .primary)
                Spacer(minLength: 4)
                if entry.isMissing {
                    Text(model.t("appMissing"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                runningDot(entry)
            }
            .frame(height: DockHelperLayout.listRowHeight - 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focusedIndex, equals: index)
        .onKeyPress(.downArrow) { moveFocus(to: index + 1) }
        .onKeyPress(.upArrow) { moveFocus(to: index - 1) }
        .accessibilityLabel(entry.isMissing ? "\(entry.displayName) — \(model.t("appMissing"))" : entry.displayName)
        .accessibilityValue(entry.isRunning ? model.t("running") : model.t("notRunning"))
        .contextMenu {
            Button(role: .destructive) {
                model.removeApp(entry)
            } label: {
                Label(model.t("removeFromGroup"), systemImage: "minus.circle")
            }
        }
        .draggable(Self.dragPrefix + entry.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            drop(items, onto: entry.id)
        } isTargeted: { targeted in
            updateDropTarget(targeted, id: entry.id)
        }
        .opacity(dropTargetID == entry.id ? 0.65 : 1)
    }

    @ViewBuilder
    private func appIcon(_ entry: DockHelperModel.Entry, side: CGFloat) -> some View {
        ZStack(alignment: .bottomTrailing) {
            if let icon = entry.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: side, height: side)
            } else if entry.isMissing {
                RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
                    .fill(.quaternary)
                    .frame(width: side, height: side)
                    .overlay(
                        Image(systemName: "questionmark.app")
                            .font(.system(size: side * 0.5))
                            .foregroundStyle(.secondary)
                    )
            } else {
                // 图标还在渲染：中性占位方块，不要画成「应用未找到」。
                RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
                    .fill(.quaternary)
                    .frame(width: side, height: side)
            }
            if entry.isRunning {
                Circle()
                    .fill(.green)
                    .frame(width: side * 0.24, height: side * 0.24)
                    .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                    .offset(x: side * 0.06, y: side * 0.06)
            }
        }
        .frame(width: side, height: side)
    }

    private func runningDot(_ entry: DockHelperModel.Entry) -> some View {
        Circle()
            .strokeBorder(entry.isRunning ? .green : .secondary.opacity(0.5), lineWidth: entry.isRunning ? 0 : 1.5)
            .background(Circle().fill(entry.isRunning ? .green : .clear))
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }

    /// 方向键在 Grid / List 中移动焦点，符合「支持键盘导航」的要求。
    private func moveFocus(to index: Int) -> KeyPress.Result {
        guard !model.entries.isEmpty else { return .ignored }
        focusedIndex = min(max(index, 0), model.entries.count - 1)
        return .handled
    }

    /// 拖到某一格上：落点索引就是移动后的索引（拖到最后一项即移到末尾）。
    private func drop(_ items: [String], onto entryID: UUID) -> Bool {
        guard let payload = items.first,
              payload.hasPrefix(Self.dragPrefix),
              let draggedID = UUID(uuidString: String(payload.dropFirst(Self.dragPrefix.count))),
              draggedID != entryID,
              let index = model.entries.firstIndex(where: { $0.id == entryID })
        else { return false }
        model.moveApp(id: draggedID, to: index)
        dropTargetID = nil
        return true
    }

    private func updateDropTarget(_ targeted: Bool, id: UUID) {
        if targeted {
            dropTargetID = id
        } else if dropTargetID == id {
            dropTargetID = nil
        }
    }
}
