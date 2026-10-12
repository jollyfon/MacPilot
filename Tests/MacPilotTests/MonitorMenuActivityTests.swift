import AppKit
import Testing
@testable import MacPilot

@MainActor
struct MonitorMenuActivityTests {
    @Test func duplicateBeginAndUnknownEndDoNotCorruptTrackingState() {
        let center = NotificationCenter()
        let activity = MonitorMenuActivity(notificationCenter: center)
        let menu = NSMenu(title: "tracked")
        let unknownMenu = NSMenu(title: "unknown")

        #expect(!activity.isTracking)
        center.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        center.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        #expect(activity.isTracking)

        center.post(name: NSMenu.didEndTrackingNotification, object: unknownMenu)
        #expect(activity.isTracking)

        center.post(name: NSMenu.didEndTrackingNotification, object: menu)
        #expect(!activity.isTracking)
    }

    @Test func nestedMenusKeepTrackingUntilEveryMenuEnds() {
        let center = NotificationCenter()
        let activity = MonitorMenuActivity(notificationCenter: center)
        let firstMenu = NSMenu(title: "first")
        let secondMenu = NSMenu(title: "second")

        center.post(name: NSMenu.didBeginTrackingNotification, object: firstMenu)
        center.post(name: NSMenu.didBeginTrackingNotification, object: secondMenu)
        #expect(activity.isTracking)

        center.post(name: NSMenu.didEndTrackingNotification, object: firstMenu)
        #expect(activity.isTracking)

        center.post(name: NSMenu.didEndTrackingNotification, object: secondMenu)
        #expect(!activity.isTracking)
    }

    @Test func notificationsForAnUntrackedObjectDoNotStartTracking() {
        let center = NotificationCenter()
        let activity = MonitorMenuActivity(notificationCenter: center)

        center.post(name: NSMenu.didEndTrackingNotification, object: NSMenu(title: "never began"))
        #expect(!activity.isTracking)
    }
}
