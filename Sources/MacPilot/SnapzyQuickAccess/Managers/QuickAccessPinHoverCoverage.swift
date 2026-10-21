//
//  QuickAccessPinHoverCoverage.swift
//  MacPilot
//
//  Is the pointer actually on the pin, or is something else drawn over it?
//
//  A pin sits above normal windows, but menus, combobox dropdowns and tooltips
//  sit above the pin.  The pin's hover logic used to ask only "is the pointer
//  inside my frame", so moving the mouse across another application's dropdown
//  that happens to hang over a pin made the pin reveal its chrome and take key
//  window status — which is what closed that dropdown.  The user could never
//  reach an item that overlapped the pin.
//
//  The answer costs a walk of the window server's on-screen list, so the sweep
//  is edge-triggered and throttled rather than run per pointer event: see
//  `QuickAccessPinHoverCoverage.sweepIsWorthRunning`.
//

import AppKit

@MainActor
enum QuickAccessPinHoverCoverage {
    /// One entry of a front-to-back on-screen sweep, in AppKit global space.
    struct Surface: Equatable, Sendable {
        let windowNumber: CGWindowID
        let frame: CGRect
    }

    /// Whether the pin is the window the pointer is on.  The sweep comes ordered
    /// front-to-back, so the first surface holding the point owns that pixel: if
    /// it is not the pin, something is drawn over the pin and the pin must not
    /// react to the pointer at all.
    ///
    /// A sweep that does not contain the pin at all answers "exposed".  A short
    /// read must not put a pin to sleep — the geometric frame test is still what
    /// decides the hover, exactly as before this check existed.
    static func isPinExposed(
        at point: CGPoint,
        pinWindowNumber: CGWindowID,
        surfaces: [Surface]
    ) -> Bool {
        guard let topmost = surfaces.first(where: { $0.frame.contains(point) }) else { return true }
        return topmost.windowNumber == pinWindowNumber
    }

    /// Whether a sweep may run now.  Two moments can change what the pin would do
    /// next: the pointer crossing into the frame (the hover is about to turn on)
    /// and the pin not being key while inside (the very next move would take key
    /// status, the one action that closes another application's popup).  While a
    /// cover is holding the hover down, the verdict is re-asked on an interval so
    /// the pin wakes up as soon as the popup is gone.  An exposed, already-key pin
    /// needs no answer at all, which keeps the steady state sweep-free.
    static func sweepIsWorthRunning(
        pointerIsInsideFrame: Bool,
        didCrossIntoFrame: Bool,
        isKeyWindow: Bool,
        hoverIsSuppressed: Bool,
        lastSweepAt: Date?,
        now: Date
    ) -> Bool {
        guard pointerIsInsideFrame else { return false }
        if didCrossIntoFrame { return true }
        guard !isKeyWindow || hoverIsSuppressed else { return false }
        guard let lastSweepAt else { return true }
        return now.timeIntervalSince(lastSweepAt) >= reprobeInterval
    }

    static let reprobeInterval: TimeInterval = 0.2

    /// The live sweep.  This is the expensive half, so callers gate it behind
    /// `sweepIsWorthRunning`.  Zero-alpha windows are dropped: an invisible
    /// surface does not own the pixel the pointer is on.
    static func liveSurfaces() -> [Surface] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }

        // Quartz's global space hangs off the top-left of the main display, AppKit's
        // off its bottom-left, so the whole sweep needs one height and one subtraction.
        // Per-window display mapping would be the right thing for a one-off query and
        // far too expensive for something that runs on pointer movement.
        let mainDisplayHeight = NSScreen.screens
            .first(where: { $0.displayID == CGMainDisplayID() })?.frame.height
            ?? CGDisplayBounds(CGMainDisplayID()).height
        guard mainDisplayHeight > 0 else { return [] }

        let dockPID = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock")
            .first?.processIdentifier
        return surfaces(from: info, mainDisplayHeight: mainDisplayHeight, dockPID: dockPID)
    }

    /// Split out from `liveSurfaces` so the Dock exclusion can be exercised with
    /// window-server-shaped entries instead of the live list.
    static func surfaces(
        from info: [[String: Any]],
        mainDisplayHeight: CGFloat,
        dockPID: pid_t?
    ) -> [Surface] {
        var surfaces: [Surface] = []
        surfaces.reserveCapacity(info.count)
        for entry in info {
            guard let number = entry[kCGWindowNumber as String] as? NSNumber,
                  ((entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                  let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                  let quartz = CGRect(dictionaryRepresentation: boundsDictionary)?.standardized
            else { continue }

            let ownerPID = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            let level = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard !isDockSurface(ownerPID: ownerPID, level: level, dockPID: dockPID) else { continue }

            surfaces.append(Surface(
                windowNumber: CGWindowID(number.uint32Value),
                frame: CGRect(
                    x: quartz.minX,
                    y: mainDisplayHeight - quartz.maxY,
                    width: quartz.width,
                    height: quartz.height
                )
            ))
        }
        return surfaces
    }

    /// The Dock keeps one container window spanning the whole display for its
    /// strip and magnification.  Its rectangle therefore claims every pixel on
    /// the main display even though the Dock only owns the strip — counting it
    /// as a cover made pins there never see the pointer, while pins on displays
    /// without a Dock worked.  Dock menus ride at popup levels and still count.
    static func isDockSurface(ownerPID: pid_t?, level: Int, dockPID: pid_t?) -> Bool {
        guard let dockPID, ownerPID == dockPID else { return false }
        return level <= Int(CGWindowLevelForKey(.dockWindow))
    }
}
