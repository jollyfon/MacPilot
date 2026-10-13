import Carbon.HIToolbox
import Testing
@testable import MacPilot

@Suite(.serialized)
struct CarbonHotKeyRoutingTests {
    @Test @MainActor
    func screenshotHotKeyPassesThroughClipboardHandler() throws {
        let event = try makeHotKeyEvent(
            signature: OSType(0x4D504341), // "MPCA"
            identifier: 1
        )
        defer { ReleaseEvent(event) }

        // Carbon calls the most recently installed handler first, so install
        // the fake screenshot receiver first and the real clipboard handler
        // last to put it at the head of the dispatch chain.
        let screenshotContext = DownstreamHotKeyProbe()
        var screenshotHandler: EventHandlerRef?
        var eventType = hotKeyEventType
        try #require(InstallEventHandler(
            GetApplicationEventTarget(),
            downstreamScreenshotHotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(screenshotContext).toOpaque(),
            &screenshotHandler
        ) == noErr)
        let installedScreenshotHandler = try #require(screenshotHandler)
        defer { RemoveEventHandler(installedScreenshotHandler) }

        let clipboardContext = ClipboardHotKeyContext(onToggle: {})
        var clipboardHandler: EventHandlerRef?
        eventType = hotKeyEventType
        try #require(InstallEventHandler(
            GetApplicationEventTarget(),
            clipboardHotKeyEventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(clipboardContext).toOpaque(),
            &clipboardHandler
        ) == noErr)
        let installedClipboardHandler = try #require(clipboardHandler)
        defer { RemoveEventHandler(installedClipboardHandler) }

        #expect(SendEventToEventTarget(event, GetApplicationEventTarget()) == noErr)
        #expect(screenshotContext.didReceiveEvent)
    }

    @Test
    func screenRecordingHandlerPassesThroughForeignHotKeyWithoutContext() throws {
        let event = try makeHotKeyEvent(signature: OSType(0x4D504341), identifier: 1)
        defer { ReleaseEvent(event) }

        #expect(screenRecordingCarbonEventHandler(nil, event, nil) == OSStatus(eventNotHandledErr))
    }

    @Test @MainActor
    func clipboardHotKeyStillInvokesItsOwnHandler() async throws {
        let event = try makeHotKeyEvent(
            signature: ClipboardHotKeyCenter.hotKeySignature,
            identifier: ClipboardHotKeyCenter.hotKeyIdentifier
        )
        defer { ReleaseEvent(event) }

        let toggleProbe = ClipboardToggleProbe()
        let clipboardContext = ClipboardHotKeyContext {
            toggleProbe.invocationCount += 1
        }
        var eventType = hotKeyEventType
        var handler: EventHandlerRef?
        try #require(InstallEventHandler(
            GetApplicationEventTarget(),
            clipboardHotKeyEventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(clipboardContext).toOpaque(),
            &handler
        ) == noErr)
        let installedHandler = try #require(handler)
        defer { RemoveEventHandler(installedHandler) }

        #expect(SendEventToEventTarget(event, GetApplicationEventTarget()) == noErr)
        for _ in 0..<10 where toggleProbe.invocationCount == 0 {
            await Task.yield()
        }
        #expect(toggleProbe.invocationCount == 1)
    }
}

private let hotKeyEventType = EventTypeSpec(
    eventClass: OSType(kEventClassKeyboard),
    eventKind: UInt32(kEventHotKeyPressed)
)

private final class DownstreamHotKeyProbe: @unchecked Sendable {
    var didReceiveEvent = false
}

@MainActor
private final class ClipboardToggleProbe {
    var invocationCount = 0
}

private func makeHotKeyEvent(signature: OSType, identifier: UInt32) throws -> EventRef {
    var event: EventRef?
    try #require(CreateEvent(
        nil,
        OSType(kEventClassKeyboard),
        UInt32(kEventHotKeyPressed),
        0,
        EventAttributes(kEventAttributeUserEvent),
        &event
    ) == noErr)
    let createdEvent = try #require(event)

    var hotKeyID = EventHotKeyID(signature: signature, id: identifier)
    let setParameterStatus = withUnsafePointer(to: &hotKeyID) { pointer in
        SetEventParameter(
            createdEvent,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            MemoryLayout<EventHotKeyID>.size,
            UnsafeRawPointer(pointer)
        )
    }
    guard setParameterStatus == noErr else {
        ReleaseEvent(createdEvent)
        throw CarbonHotKeyRoutingError.eventParameterSetupFailed(setParameterStatus)
    }
    return createdEvent
}

private func downstreamScreenshotHotKeyHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    let probe = Unmanaged<DownstreamHotKeyProbe>
        .fromOpaque(userData)
        .takeUnretainedValue()
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
    guard status == noErr else { return status }
    probe.didReceiveEvent = true
    return noErr
}

private enum CarbonHotKeyRoutingError: Error {
    case eventParameterSetupFailed(OSStatus)
}
