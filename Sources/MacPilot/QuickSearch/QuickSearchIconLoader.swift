//
//  QuickSearchIconLoader.swift
//  MacPilot
//
//  结果行图标：异步、按可见行取、去重、限并发、有容量上限、内存压力下主动清空。
//
//  尺寸收缩沿用 Dock Groups 的 `DockGroupIconThumbnail`：`NSWorkspace.icon(forFile:)`
//  返回的是多表示图，只改 `NSImage.size` 底下仍是 1024×1024，一上屏就会物化出
//  几十 MB。这里在后台把它重绘成目标像素尺寸的小图，跨 actor 只传 `Data`。
//

import AppKit
import Foundation
import MacPilotDockGroupsCore

@MainActor
final class QuickSearchIconLoader: ObservableObject {
    struct Request {
        let key: String
        let url: URL
        let pointSize: CGFloat
    }

    /// 结果行按需取图，容量按一屏可见行数放大几倍即可，不预加载系统全部图标。
    static let cacheCountLimit = 240
    static let cacheByteLimit = 8 * 1024 * 1024
    static let maximumConcurrentLoads = 4

    /// 图标到达后合并刷新用的版本号。视图观察它，而不是每条图标各刷一次。
    @Published private(set) var revision = 0

    private let cache = NSCache<NSString, QuickSearchCachedIcon>()
    private let tracker = QuickSearchIconEvictionTracker()
    private var inFlight: Set<String> = []
    private var queue: [Request] = []
    private var activeLoads = 0
    private var failedKeys: Set<String> = []
    private var loadGeneration = 0
    private var loadTasks: [String: Task<Void, Never>] = [:]
    private var flushTask: Task<Void, Never>?
    private var flushScheduled = false
    private var memoryPressureToken: UUID?
    private var imageLoader: @Sendable (URL, CGFloat) -> Data?

    private(set) var pendingRequestCount = 0

    var cachedEntryCount: Int { tracker.count }
    var estimatedBytes: Int { tracker.bytes }
    var activeLoadCount: Int { activeLoads }
    var diagnosticTaskCount: Int { loadTasks.count + (flushTask == nil ? 0 : 1) }

    init(imageLoader: (@Sendable (URL, CGFloat) -> Data?)? = nil) {
        self.imageLoader = imageLoader ?? { url, pointSize in
            DockGroupIconThumbnail.pngData(forFileAt: url, pointSize: pointSize)
        }
        cache.countLimit = Self.cacheCountLimit
        cache.totalCostLimit = Self.cacheByteLimit
        cache.delegate = tracker
    }

    /// 订阅进程内存压力：压力来临时立刻交还图标缓存，交互重建即可。
    func startMemoryPressureHandling() {
        guard memoryPressureToken == nil else { return }
        memoryPressureToken = MemoryPressure.shared.observe { [weak self] in
            self?.purgeCache()
        }
    }

    func stop() {
        cancelPendingLoads()
        purgeCache()
        MemoryPressure.shared.cancel(memoryPressureToken)
        memoryPressureToken = nil
    }

    /// 已缓存则返回图片；未缓存则发起加载并返回 nil（视图先占位，图标到达后合并刷新）。
    func icon(for url: URL, pointSize: CGFloat = 32, key: String? = nil) -> NSImage? {
        let iconKey = key ?? url.standardizedFileURL.path
        if let cached = cache.object(forKey: iconKey as NSString) { return cached.image }
        guard !failedKeys.contains(iconKey) else { return nil }
        request(key: iconKey, url: url, pointSize: pointSize)
        return nil
    }

    func purgeCache() {
        cache.removeAllObjects()
        tracker.clear()
    }

    // MARK: - 加载

    private func request(key: String, url: URL, pointSize: CGFloat) {
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        pendingRequestCount = inFlight.count
        queue.append(Request(key: key, url: url, pointSize: pointSize))
        drainQueue()
    }

    private func drainQueue() {
        while activeLoads < Self.maximumConcurrentLoads, !queue.isEmpty {
            let request = queue.removeFirst()
            let generation = loadGeneration
            let loader = imageLoader
            activeLoads += 1
            let worker = Task.detached(priority: .userInitiated) {
                loader(request.url, request.pointSize)
            }
            loadTasks[request.key] = Task { [weak self] in
                let data = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard let self, self.loadGeneration == generation, !Task.isCancelled else { return }
                self.activeLoads -= 1
                self.loadTasks[request.key] = nil
                self.inFlight.remove(request.key)
                self.pendingRequestCount = self.inFlight.count
                if let data, let image = Self.image(from: data, pointSize: request.pointSize) {
                    self.store(image, for: request.key, pixelSide: DockGroupIconThumbnail.pixelSize(
                        forPoints: request.pointSize
                    ))
                } else {
                    // 取不到就记下来，避免每次重绘都重新问一遍图标服务。
                    self.failedKeys.insert(request.key)
                }
                self.scheduleFlush()
                self.drainQueue()
            }
        }
    }

    private func store(_ image: NSImage, for key: String, pixelSide: Int) {
        let cost = max(1, pixelSide * pixelSide * 4)
        let box = QuickSearchCachedIcon(key: key, image: image, cost: cost)
        tracker.insert(box)
        cache.setObject(box, forKey: key as NSString, cost: cost)
    }

    /// NSImage 不是 Sendable：位图只在这里、也就是主 Actor 上组装。
    private static func image(from data: Data, pointSize: CGFloat) -> NSImage? {
        guard let image = NSImage(data: data) else { return nil }
        image.size = NSSize(width: pointSize, height: pointSize)
        return image
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        flushTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.flushScheduled = false
            self.flushTask = nil
            self.revision &+= 1
        }
    }

    private func cancelPendingLoads() {
        loadGeneration &+= 1
        for task in loadTasks.values { task.cancel() }
        loadTasks.removeAll()
        queue.removeAll()
        activeLoads = 0
        inFlight.removeAll()
        pendingRequestCount = 0
        failedKeys.removeAll()
        flushTask?.cancel()
        flushTask = nil
        flushScheduled = false
    }
}

private final class QuickSearchCachedIcon: NSObject {
    let key: String
    let image: NSImage
    let cost: Int
    let identity = UUID()

    init(key: String, image: NSImage, cost: Int) {
        self.key = key
        self.image = image
        self.cost = cost
    }
}

/// `NSCache` 自己按成本淘汰，这里的账本让「还剩多少、占多少字节」可被诊断读取。
/// 与 `AppIconCache` 同构：淘汰回调按 identity 比对，避免把新条目账目删掉。
private final class QuickSearchIconEvictionTracker: NSObject, NSCacheDelegate {
    private let lock = NSLock()
    private var entries: [String: (identity: UUID, cost: Int)] = [:]

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    var bytes: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.values.reduce(0) { $0 + $1.cost }
    }

    func insert(_ icon: QuickSearchCachedIcon) {
        lock.lock()
        entries[icon.key] = (icon.identity, icon.cost)
        lock.unlock()
    }

    func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject object: Any) {
        guard let icon = object as? QuickSearchCachedIcon else { return }
        lock.lock()
        if entries[icon.key]?.identity == icon.identity { entries.removeValue(forKey: icon.key) }
        lock.unlock()
    }
}
