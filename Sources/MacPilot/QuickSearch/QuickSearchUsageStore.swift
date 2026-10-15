//
//  QuickSearchUsageStore.swift
//  MacPilot
//
//  应用使用频次与最近使用记录。数量有限、丢失可接受（只影响排序提示），
//  所以用一条受限的 UserDefaults 记录，不为本功能新增 SQLite 数据库。
//

import Foundation

struct QuickSearchUsageRecord: Codable, Equatable, Sendable {
    /// 归并键：Bundle ID 优先，没有则用路径。App 移动后仍能延续使用记录。
    let identity: String
    let path: String
    let count: Int
    let lastUsed: Date
}

@MainActor
final class QuickSearchUsageStore {
    /// 记录条数上限。超出时按最近使用时间丢弃最旧的，不让它无限增长。
    /// 应用和文件现在共用这一张表，所以容量按两类都记得下估算。
    static let defaultLimit = 200
    static let defaultsKey = "quickSearch.appUsage"

    private let defaults: UserDefaults
    private let limit: Int
    private(set) var records: [String: QuickSearchUsageRecord] = [:]

    var recordCount: Int { records.count }

    init(defaults: UserDefaults = .standard, limit: Int = QuickSearchUsageStore.defaultLimit) {
        self.defaults = defaults
        self.limit = max(1, limit)
        load()
    }

    nonisolated static func identity(bundleIdentifier: String?, path: String) -> String {
        if let bundleIdentifier, !bundleIdentifier.isEmpty { return "bid:\(bundleIdentifier)" }
        return "path:\(path)"
    }

    func count(for entry: QuickSearchApplicationEntry) -> Int {
        count(forIdentity: entry.usageIdentity)
    }

    /// 按归并键取次数。收藏与文件结果只有路径，也走这同一个入口。
    func count(forIdentity identity: String) -> Int {
        records[identity]?.count ?? 0
    }

    func lastUsed(for entry: QuickSearchApplicationEntry) -> Date? {
        records[Self.identity(bundleIdentifier: entry.bundleIdentifier, path: entry.path)]?.lastUsed
    }

    func recordLaunch(of entry: QuickSearchApplicationEntry) {
        recordLaunch(
            identity: Self.identity(bundleIdentifier: entry.bundleIdentifier, path: entry.path),
            path: entry.path
        )
    }

    /// 记录一次「真的打开了」。文件与文件夹用同一条键（`path:`），
    /// 所以按使用频率排序时应用和文件是一个尺子。
    func recordLaunch(identity: String, path: String) {
        let existing = records[identity]
        records[identity] = QuickSearchUsageRecord(
            identity: identity,
            path: path,
            count: (existing?.count ?? 0) + 1,
            lastUsed: Date()
        )
        trimIfNeeded()
        save()
    }

    /// 按最近使用时间排序的归并键，用于空查询时展示最近用过的应用。
    func recentIdentities(limit: Int) -> [String] {
        records.values
            .sorted { lhs, rhs in
                if lhs.lastUsed != rhs.lastUsed { return lhs.lastUsed > rhs.lastUsed }
                return lhs.identity < rhs.identity
            }
            .prefix(max(0, limit))
            .map(\.identity)
    }

    func reset() {
        records = [:]
        save()
    }

    private func trimIfNeeded() {
        guard records.count > limit else { return }
        let keep = records.values
            .sorted { lhs, rhs in
                if lhs.lastUsed != rhs.lastUsed { return lhs.lastUsed > rhs.lastUsed }
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.identity < rhs.identity
            }
            .prefix(limit)
        records = Dictionary(uniqueKeysWithValues: keep.map { ($0.identity, $0) })
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([QuickSearchUsageRecord].self, from: data)
        else { return }
        // 只认形状正确的记录；键重复时保留后一条。
        var loaded: [String: QuickSearchUsageRecord] = [:]
        for record in decoded { loaded[record.identity] = record }
        records = loaded
        trimIfNeeded()
    }

    private func save() {
        let ordered = records.values.sorted { $0.identity < $1.identity }
        guard let data = try? JSONEncoder().encode(ordered) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
