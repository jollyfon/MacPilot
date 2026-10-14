import AppKit
import Foundation
import Testing
@testable import MacPilot

@MainActor
struct ClipboardPanelPlacementTests {
    private let main = NSRect(x: 0, y: 0, width: 1_440, height: 900)

    private func place(
        _ position: ClipboardPanelPosition?,
        height: CGFloat = 340,
        screens: [NSRect]? = nil
    ) -> NSRect {
        ClipboardPanelLayout.positionedFrame(
            contentHeight: height, savedPosition: position,
            visibleFrames: screens ?? [main], preferredFrame: main
        )
    }

    @Test func firstOpenKeepsTheDefaultTopPosition() {
        let frame = place(nil)
        #expect(frame == NSRect(x: 520, y: 548, width: 400, height: 340))
    }

    @Test func reopeningRestoresTheDraggedPositionAndKeepsTheHeaderStableWhenHistoryChanges() {
        let dragged = NSRect(x: 175, y: 210, width: 400, height: 340)
        let position = ClipboardPanelPosition(frame: dragged)
        #expect(place(position) == dragged)
        let shorter = place(position, height: 200)
        #expect(shorter.minX == dragged.minX)
        #expect(shorter.maxY == dragged.maxY)
        #expect(shorter.height == 200)
    }

    @Test func draggingToAnEdgeDoesNotReserveSpaceForThePreview() {
        let dragged = NSRect(x: main.maxX - 400, y: 0, width: 400, height: 340)
        #expect(place(ClipboardPanelPosition(frame: dragged)) == dragged)
        let preview = ClipboardPanelLayout.resizedFrame(dragged, showsPreview: true, visibleFrame: main)
        #expect(preview.origin == dragged.origin)
        #expect(preview.height == dragged.height)
    }

    @Test func reopeningUsesTheSavedDisplayEvenWhenAnotherDisplayIsActive() {
        let external = NSRect(x: -1_920, y: 100, width: 1_920, height: 1_080)
        let dragged = NSRect(x: -1_000, y: 330, width: 400, height: 340)
        #expect(place(ClipboardPanelPosition(frame: dragged), screens: [main, external]) == dragged)
    }

    @Test func verticallyStackedDisplaysUseTheActualListHeight() {
        let upper = NSRect(x: 0, y: 900, width: 1_440, height: 900)
        let dragged = NSRect(x: 200, y: 900, width: 400, height: 190)
        #expect(place(ClipboardPanelPosition(frame: dragged), height: 190, screens: [main, upper]) == dragged)
    }

    @Test func disconnectedOrResizedDisplaysKeepTheListOnscreen() {
        let missingDisplay = NSRect(x: -1_000, y: 1_000, width: 400, height: 340)
        let restored = place(ClipboardPanelPosition(frame: missingDisplay))
        #expect(main.contains(restored))
        #expect(restored.minX == main.minX)
        #expect(restored.maxY == main.maxY)
        let tooLow = NSRect(x: 1_300, y: -200, width: 400, height: 340)
        #expect(main.contains(place(ClipboardPanelPosition(frame: tooLow))))
    }

    @Test func invalidCoordinatesUseTheDefaultPosition() {
        var position = ClipboardPanelPosition(frame: .zero)
        position.x = .nan
        #expect(place(position) == place(nil))
        position.x = 100
        position.y = .infinity
        #expect(place(position) == place(nil))
    }

    @Test func savedPositionSurvivesConfigurationReloadAndLegacySettingsStillDecode() throws {
        let legacy = Data(#"{"isEnabled":false,"storageLimit":500,"pasteByDefault":false,"showSearch":true,"clearSystemClipboardOnClear":false,"pinsAtTop":true,"hotkey":{"keyCode":9,"modifiers":9}}"#.utf8)
        let decoder = JSONDecoder()
        let loaded = try decoder.decode(ClipboardSettings.self, from: legacy)
        #expect(loaded.panelPosition == nil)
        #expect(loaded.storageLimit == 500)
        #expect(!loaded.pasteByDefault)
        var saved = loaded
        saved.panelPosition = ClipboardPanelPosition(frame: NSRect(x: -900, y: 200, width: 700, height: 340))
        let reloaded = try decoder.decode(ClipboardSettings.self, from: JSONEncoder().encode(saved))
        #expect(reloaded == saved)
        #expect(place(reloaded.panelPosition, screens: [main, NSRect(x: -1_920, y: 0, width: 1_920, height: 1_080)]).minX == -900)
    }

    @Test func rememberingThePositionPersistsOnceAndDoesNotLoadHistory() {
        let model = ClipboardModel()
        model.applyLoadedSettings(ClipboardSettings(), activate: false)
        var writes = 0
        model.persist = { writes += 1 }
        let dragged = NSRect(x: 240, y: 120, width: 700, height: 340)
        let position = ClipboardPanelPosition(frame: dragged)
        model.rememberPanelPosition(position)
        #expect(writes == 1)
        #expect(model.settings.panelPosition == position)
        model.rememberPanelPosition(position)
        #expect(writes == 1)
        #expect(!model.hasLoadedHistory)
        model.shutdown()
    }

    @Test func dragHintExistsInBothLanguages() {
        #expect(AppText.value("clipboardDragHint", language: .simplifiedChinese).contains("拖动"))
        #expect(AppText.value("clipboardDragHint", language: .english).contains("Drag"))
    }

    @Test func asynchronousWindowMovementIsSavedWhenThePanelClosesBeforeTheDebounce() throws {
        let directory = ClipboardContentStoreIsolation.isolate()
        defer { ClipboardContentStoreIsolation.restore(directory) }
        let model = ClipboardModel(historyStorageURL: directory.appendingPathComponent("history.json"))
        model.applyLoadedSettings(ClipboardSettings(), activate: false)
        defer { model.shutdown() }
        var writes = 0
        model.persist = { writes += 1 }
        // No visible window or real pointer injection. Native dragging returns
        // before WindowServer sends the changed frame; emulate that ordering.
        let panel = ClipboardPanel(windowDrag: { _, _ in }, onClose: {}) {
            ClipboardPanelContent(model: model)
        }
        #expect(panel.isMovable)
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1
        ))
        panel.dragFromHeader(with: event)
        #expect(model.settings.panelPosition == nil)
        #expect(writes == 0)
        panel.setFrame(NSRect(x: 150, y: 220, width: 400, height: 340), display: false)
        let finalPosition = ClipboardPanelPosition(frame: panel.frame)
        panel.close()
        #expect(model.settings.panelPosition == finalPosition)
        #expect(writes == 1)
    }
}
