import Foundation

/// 内存监控的运行时状态：定时采样进程与系统内存，供监控页展示。
@MainActor
final class MemoryMonitorModel: ManagedFeature, FeatureResourceReporting {
    let identifier = "memoryMonitor"
    var isRunning: Bool { refreshLoop.isRunning }
    var diagnosticTaskCount: Int { (refreshLoop.isRunning ? 1 : 0) + (samplingTask == nil ? 0 : 1) }
    var diagnosticObserverCount: Int { 0 }
    /// 自动刷新间隔：足够跟随变化，又不会带来可感知的开销。
    static let refreshInterval: TimeInterval = 3

    /// 菜单关闭时复用快照；实际跟踪菜单时才按短缓存刷新。
    private static let menuCache = MonitorMenuSnapshotCache {
        let samples = ProcessMemorySampler.sample()
        return (apps: AppMemoryGrouper.group(samples), system: SystemMemoryReader.snapshot())
    }

    let store = MemoryStore()

    private let refreshLoop = BackgroundTask()
    private var samplingTask: Task<Void, Never>?
    private var sampleRevision = 0

    /// Native menu construction gets initial rows immediately. Hidden
    /// evaluations reuse them; an open menu can refresh after the TTL.
    static func menuSnapshot(maxAge: TimeInterval = 2, allowsRefresh: Bool = true) -> (apps: [AppMemoryUsage], system: SystemMemorySnapshot?) {
        menuCache.snapshot(maxAge: maxAge, allowsRefresh: allowsRefresh)
    }

    func startAutoRefresh() {
        guard !refreshLoop.isRunning else { return }
        refresh()
        refreshLoop.start(interval: .seconds(Self.refreshInterval)) { [weak self] in
            self?.refresh()
        }
    }

    func stopAutoRefresh() {
        refreshLoop.stop()
        sampleRevision += 1
        samplingTask?.cancel()
        samplingTask = nil
        store.clear()
        ProcessCollector.shared.clear()
    }

    func start() { startAutoRefresh() }
    func stop() { stopAutoRefresh() }

    /// Drops the process-wide menu snapshot so a terminated app does not keep
    /// the cached `[AppMemoryUsage]` array alive.
    static func clearMenuCache() {
        menuCache.clear()
    }

    func refresh() {
        guard !store.isRefreshing else { return }
        store.beginRefresh()
        sampleRevision += 1
        let revision = sampleRevision
        samplingTask = Task.detached(priority: .utility) { [weak self] in
            let samples = ProcessMemorySampler.sample()
            let snapshot = SystemMemoryReader.snapshot()
            let apps = AppMemoryGrouper.group(samples)
            guard !Task.isCancelled else { return }
            await self?.apply(apps: apps, snapshot: snapshot, revision: revision)
        }
    }

    private func apply(apps: [AppMemoryUsage], snapshot: SystemMemorySnapshot?, revision: Int) {
        guard revision == sampleRevision else { return }
        samplingTask = nil
        store.publish(apps: apps, snapshot: snapshot)
    }
}
