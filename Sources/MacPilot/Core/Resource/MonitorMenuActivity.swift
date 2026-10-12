import AppKit
import Combine

/// Menu tracking notifications describe the native menu session, unlike
/// SwiftUI appearance callbacks which may run during offscreen construction.
@MainActor
final class MonitorMenuActivity: ObservableObject {
    static let shared = MonitorMenuActivity()

    @Published private(set) var isTracking = false
    private var trackingMenus = Set<ObjectIdentifier>()
    private var subscriptions: MonitorMenuSubscriptions?

    init(notificationCenter: NotificationCenter = .default) {
        let begin = notificationCenter.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let menu = notification.object as? NSMenu else { return }
            let identifier = ObjectIdentifier(menu)
            MainActor.assumeIsolated {
                self?.beginTracking(identifier)
            }
        }
        let end = notificationCenter.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let menu = notification.object as? NSMenu else { return }
            let identifier = ObjectIdentifier(menu)
            MainActor.assumeIsolated {
                self?.endTracking(identifier)
            }
        }
        subscriptions = MonitorMenuSubscriptions(center: notificationCenter, tokens: [begin, end])
    }

    private func beginTracking(_ identifier: ObjectIdentifier) {
        trackingMenus.insert(identifier)
        if !isTracking { isTracking = true }
    }

    private func endTracking(_ identifier: ObjectIdentifier) {
        trackingMenus.remove(identifier)
        if trackingMenus.isEmpty, isTracking { isTracking = false }
    }
}

/// NotificationCenter removal is thread safe, including actor teardown.
private final class MonitorMenuSubscriptions: @unchecked Sendable {
    let center: NotificationCenter
    let tokens: [NSObjectProtocol]

    init(center: NotificationCenter, tokens: [NSObjectProtocol]) {
        self.center = center
        self.tokens = tokens
    }

    deinit {
        for token in tokens { center.removeObserver(token) }
    }
}
