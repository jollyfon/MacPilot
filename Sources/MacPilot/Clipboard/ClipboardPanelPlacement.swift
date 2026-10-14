import AppKit

/// Store the list's top-left corner, independent of history height and preview width.
struct ClipboardPanelPosition: Codable, Equatable, Sendable {
    var x: Double
    var y: Double

    init(frame: NSRect) {
        x = Double(frame.minX)
        y = Double(frame.maxY)
    }

    var isFinite: Bool { x.isFinite && y.isFinite }
}

extension ClipboardPanelLayout {
    static func positionedFrame(
        contentHeight: CGFloat,
        savedPosition: ClipboardPanelPosition?,
        visibleFrames: [NSRect],
        preferredFrame: NSRect
    ) -> NSRect {
        let position = savedPosition.flatMap { $0.isFinite ? $0 : nil }
        let proposedHeight = min(max(contentHeight, minimumHeight), maximumHeight)
        let proposed = position.map {
            NSRect(x: $0.x, y: $0.y - Double(proposedHeight), width: listColumnWidth, height: proposedHeight)
        }
        // Choose by the list's overlap, not the preview column or NSScreen.main.
        // A disconnected display falls back to the current active display.
        let matchingFrame = proposed.flatMap { proposed in
            visibleFrames.max { first, second in
                intersectionArea(proposed, first) < intersectionArea(proposed, second)
            }.flatMap { intersectionArea(proposed, $0) > 0 ? $0 : nil }
        }
        let visibleFrame = matchingFrame ?? preferredFrame
        let height = max(1, min(max(contentHeight, minimumHeight), maximumHeight, visibleFrame.height - 60))
        let width = min(listColumnWidth, max(1, visibleFrame.width - 24))
        let inset: CGFloat = position == nil ? 12 : 0
        let x: CGFloat
        let top: CGFloat
        if let position {
            x = CGFloat(position.x)
            top = CGFloat(position.y)
        } else {
            let roomForExpansion = visibleFrame.maxX - 12 - self.width(showsPreview: true)
            x = min(visibleFrame.midX - width / 2, max(roomForExpansion, visibleFrame.minX + 12))
            top = visibleFrame.maxY - 12
        }
        return NSRect(
            x: min(max(x, visibleFrame.minX + inset), visibleFrame.maxX - width - inset),
            y: min(max(top - height, visibleFrame.minY + inset), visibleFrame.maxY - height - inset),
            width: width,
            height: height
        )
    }

    private static func intersectionArea(_ first: NSRect, _ second: NSRect) -> CGFloat {
        let intersection = first.intersection(second)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}
