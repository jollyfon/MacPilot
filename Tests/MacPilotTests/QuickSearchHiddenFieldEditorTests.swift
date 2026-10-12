import AppKit
import Carbon.HIToolbox
import Testing
@testable import MacPilot

@MainActor
struct QuickSearchHiddenFieldEditorTests {
    @Test func hiddenPanelFieldEditorDeliversReturnAndEscapeCommands() throws {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 60),
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        defer { panel.close() }

        let field = QuickSearchQueryTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        panel.contentView?.addSubview(field)
        var commands: [QuickSearchKeyAction] = []
        field.onCommand = { commands.append($0) }

        #expect(!panel.isVisible)
        #expect(!panel.isKeyWindow)
        #expect(panel.makeFirstResponder(field))
        let editor = try #require(panel.fieldEditor(false, for: field) as? NSTextView)

        let returnEvent = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: UInt16(kVK_Return)
        ))
        editor.keyDown(with: returnEvent)

        let escapeEvent = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: UInt16(kVK_Escape)
        ))
        editor.keyDown(with: escapeEvent)

        #expect(commands == [.openSelection, .closePanel])
        #expect(!panel.isVisible)
        #expect(!panel.isKeyWindow)
    }
}
