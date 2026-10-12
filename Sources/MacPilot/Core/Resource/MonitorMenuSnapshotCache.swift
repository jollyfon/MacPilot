import Foundation

/// Native menus need their initial rows before appearance callbacks. Later
/// view evaluations may reuse that snapshot while the menu is closed.
@MainActor
final class MonitorMenuSnapshotCache<Value> {
    private let clock: () -> TimeInterval
    private let sample: () -> Value
    private var cached: (sampledAt: TimeInterval, value: Value)?

    init(
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sample: @escaping () -> Value
    ) {
        self.clock = clock
        self.sample = sample
    }

    func snapshot(maxAge: TimeInterval = 2, allowsRefresh: Bool = true) -> Value {
        if let cached, !allowsRefresh || clock() - cached.sampledAt < maxAge {
            return cached.value
        }
        let value = sample()
        cached = (clock(), value)
        return value
    }

    func clear() {
        cached = nil
    }
}
