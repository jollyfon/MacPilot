//
//  QuickSearchPanelPlacement.swift
//  MacPilot
//
//  面板位置的纯计算：默认位置、记住的位置、越界回收。
//
//  与剪贴板面板同一套做法（`ClipboardPanelPlacement`）：存的是**左上角**，不是
//  frame 原点。面板高度随结果行数变化，锚在上沿才不会在结果变多时往上长、把
//  输入行顶出屏幕。
//

import AppKit

/// 面板左上角的屏幕坐标（AppKit 全局空间，原点在主屏左下角）。
struct QuickSearchPanelPosition: Codable, Equatable, Sendable {
    var x: Double
    var y: Double

    init(frame: NSRect) {
        x = Double(frame.minX)
        y = Double(frame.maxY)
    }

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    var isFinite: Bool { x.isFinite && y.isFinite }
}

extension QuickSearchPanelLayout {
    /// 面板尺寸完全由「这次有几行结果」和所在屏决定：行高固定，
    /// 键盘导航与滚动位置才可预测。
    static func size(rowCount: Int, visibleFrame: NSRect) -> NSSize {
        let width = max(minimumWidth, min(defaultWidth, visibleFrame.width - 80))
        let rows = min(CGFloat(rowCount), CGFloat(preferredVisibleRows))
        let contentHeight = headerHeight
            + searchFieldHeight
            + rows * rowHeight
            + (rows > 0 ? 20 : 120)   // 结果区留白；无结果时给状态文案留出空间
            + footerHeight
        return NSSize(
            width: width,
            height: min(max(contentHeight, 180), visibleFrame.height - 80)
        )
    }

    /// `savedPosition == nil` 用默认落点（指针所在屏的上三分之一、水平居中）；
    /// 有记住的位置就原样放回，只在它跑到看不见的地方时收回屏幕内。
    ///
    /// 多显示器下按「和哪块屏重叠最多」选回收边界，而不是 `NSScreen.main`：
    /// 拔掉一块屏之后记住的坐标还在，但不能回到一个用户看不到的位置。
    static func positionedFrame(
        rowCount: Int,
        savedPosition: QuickSearchPanelPosition?,
        visibleFrames: [NSRect],
        preferredFrame: NSRect
    ) -> NSRect {
        let position = savedPosition
        let probeSize = size(rowCount: rowCount, visibleFrame: preferredFrame)
        let probe = position.map {
            NSRect(x: $0.x, y: $0.y - probeSize.height, width: probeSize.width, height: probeSize.height)
        }
        let visibleFrame = probe
            .flatMap { rect in
                visibleFrames
                    .max { lhs, rhs in intersectionArea(rect, lhs) < intersectionArea(rect, rhs) }
                    .flatMap { intersectionArea(rect, $0) > 0 ? $0 : nil }
            }
            ?? preferredFrame

        let size = size(rowCount: rowCount, visibleFrame: visibleFrame)
        let origin: NSPoint
        if let probe {
            origin = probe.origin
        } else {
            origin = NSPoint(
                x: visibleFrame.midX - size.width / 2,
                y: max(
                    min(visibleFrame.maxY - size.height - 96, visibleFrame.maxY - visibleFrame.height * 0.45),
                    visibleFrame.minY + 40
                )
            )
        }
        // 默认落点自己已经带了边距；记住的位置要能被精确还原，所以只在真的越界时收。
        let inset: CGFloat = position == nil ? 12 : 0
        let lowerX = visibleFrame.minX + inset
        let lowerY = visibleFrame.minY + inset
        return NSRect(
            x: min(max(origin.x, lowerX), max(lowerX, visibleFrame.maxX - size.width - inset)),
            y: min(max(origin.y, lowerY), max(lowerY, visibleFrame.maxY - size.height - inset)),
            width: size.width,
            height: size.height
        )
    }

    private static func intersectionArea(_ first: NSRect, _ second: NSRect) -> CGFloat {
        let intersection = first.intersection(second)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}
