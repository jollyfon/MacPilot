import Foundation

/// CPU 监控的运行时状态：定时采样进程与系统 CPU，供监控页和菜单栏使用。
@MainActor
final class CPUMonitorModel: ManagedFeature, FeatureResourceReporting {
    let identifier = "cpuMonitor"
    var isRunning: Bool { refreshLoop.isRunning }
    var diagnosticTaskCount: Int { (refreshLoop.isRunning ? 1 : 0) + (samplingTask == nil ? 0 : 1) }
    var diagnosticObserverCount: Int { 0 }
    static let refreshInterval: TimeInterval = 3

    private static let menuSampler = CPUUsageSampler()
    private static let menuCache = MonitorMenuSnapshotCache {
        let result = menuSampler.sample()
        return (apps: result.apps, system: result.system)
    }

    let store = CPUStore()

    private let sampler = CPUUsageSampler()
    private let refreshLoop = BackgroundTask()
    private var samplingTask: Task<Void, Never>?
    private var sampleRevision = 0

    /// Warm the first native menu construction, then expire snapshots only
    /// while menu tracking permits another process scan.
    static func menuSnapshot(maxAge: TimeInterval = 2, allowsRefresh: Bool = true) -> (
        apps: [AppCPUUsage],
        system: SystemCPUSnapshot?
    ) {
        menuCache.snapshot(maxAge: maxAge, allowsRefresh: allowsRefresh)
    }

    func startAutoRefresh() {
        guard !refreshLoop.isRunning else { return }
        sampler.reset()
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
        sampler.reset()
        store.clear()
        ProcessCollector.shared.clear()
    }

    func start() { startAutoRefresh() }
    func stop() { stopAutoRefresh() }

    static func clearMenuCache() {
        menuCache.clear()
        menuSampler.reset()
    }

    func refresh() {
        guard !store.isRefreshing else { return }
        store.beginRefresh()
        sampleRevision += 1
        let revision = sampleRevision
        let sampler = self.sampler
        samplingTask = Task.detached(priority: .utility) { [weak self, sampler] in
            let result = sampler.sample()
            guard !Task.isCancelled else { return }
            await self?.apply(result, revision: revision)
        }
    }

    private func apply(_ result: CPUUsageSampleResult, revision: Int) {
        guard revision == sampleRevision else { return }
        samplingTask = nil
        store.publish(result)
    }
}
