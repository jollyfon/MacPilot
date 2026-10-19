import AppKit

@MainActor
protocol QuickAccessPinMouseTracking: AnyObject {
  func updateMousePassthrough(at point: CGPoint, now: Date)
}

/// All pins share one pair of event monitors. AppKit delivers both handlers on
/// the main thread, so mouse movement needs no per-window asynchronous tasks.
@MainActor
final class QuickAccessPinMouseMonitor {
  typealias Handler = @MainActor () -> Void
  typealias Installer = @MainActor (@escaping Handler) -> [Any]

  static let shared = QuickAccessPinMouseMonitor()

  private struct Target {
    weak var value: (any QuickAccessPinMouseTracking)?
  }

  private var targets: [ObjectIdentifier: Target] = [:]
  private var monitors: [Any] = []
  private let install: Installer
  private let uninstall: (Any) -> Void

  init(
    install: @escaping Installer = QuickAccessPinMouseMonitor.installLiveMonitors,
    uninstall: @escaping (Any) -> Void = { NSEvent.removeMonitor($0) }
  ) {
    self.install = install
    self.uninstall = uninstall
  }

  func add(_ target: any QuickAccessPinMouseTracking) {
    targets[ObjectIdentifier(target)] = Target(value: target)
    guard monitors.isEmpty else { return }
    monitors = install { [weak self] in
      self?.dispatch(at: NSEvent.mouseLocation, now: Date())
    }
  }

  func remove(_ target: any QuickAccessPinMouseTracking) {
    targets.removeValue(forKey: ObjectIdentifier(target))
    pruneTargets()
  }

  func dispatch(at point: CGPoint, now: Date) {
    // Snapshot permits a callback to close or suspend a pin during delivery.
    for (id, target) in targets {
      guard let value = target.value else {
        targets.removeValue(forKey: id)
        continue
      }
      guard targets[id] != nil else { continue }
      value.updateMousePassthrough(at: point, now: now)
    }
    stopIfEmpty()
  }

  private func pruneTargets() {
    targets = targets.filter { $0.value.value != nil }
    stopIfEmpty()
  }

  private func stopIfEmpty() {
    guard targets.isEmpty else { return }
    monitors.forEach(uninstall)
    monitors.removeAll()
  }

  private static func installLiveMonitors(_ handler: @escaping Handler) -> [Any] {
    let mask: NSEvent.EventTypeMask = [
      .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged
    ]
    var result: [Any] = []
    if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
      MainActor.assumeIsolated { handler() }
      return event
    }) {
      result.append(local)
    }
    if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { _ in
      MainActor.assumeIsolated { handler() }
    }) {
      result.append(global)
    }
    return result
  }
}
