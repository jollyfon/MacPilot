//
//  QuickSearchFavorites.swift
//  MacPilot
//
//  收藏：用户显式钉住的一小批结果，空查询时排在最前面。
//
//  记录里存的是**快照**（名称、副标题、路径、类型），所以渲染一行不需要碰磁盘，
//  索引还没建完时收藏也照样在。应用在实时索引里能查到就用索引里的（改名、移动
//  都跟着走），查不到就退回快照——「索引正在建」不该表现成「收藏空了」。
//  路径真的没了，打开时由既有的「找不到」提示说明，不在这里静默消失。
//

import Foundation

struct QuickSearchFavorite: Codable, Equatable, Sendable {
    /// 归并键，与 `QuickSearchUsageStore` 同一套：应用优先 Bundle ID，其余用路径。
    let identity: String
    let path: String
    let kind: QuickSearchResult.Kind
    let title: String
    let subtitle: String
    let bundleIdentifier: String?
    /// 加入收藏的时刻，用量相同的稳定次序。
    let addedAt: Date

    init(
        identity: String,
        path: String,
        kind: QuickSearchResult.Kind,
        title: String,
        subtitle: String,
        bundleIdentifier: String? = nil,
        addedAt: Date = Date()
    ) {
        self.identity = identity
        self.path = path
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.bundleIdentifier = bundleIdentifier
        self.addedAt = addedAt
    }

    init(result: QuickSearchResult, addedAt: Date = Date()) {
        self.init(
            identity: QuickSearchUsageStore.identity(
                bundleIdentifier: result.bundleIdentifier,
                path: result.url.standardizedFileURL.path
            ),
            path: result.url.standardizedFileURL.path,
            kind: result.kind,
            title: result.title,
            subtitle: result.subtitle,
            bundleIdentifier: result.bundleIdentifier,
            addedAt: addedAt
        )
    }

    var url: URL { URL(fileURLWithPath: path) }

    var result: QuickSearchResult {
        QuickSearchResult(
            kind: kind,
            title: title,
            subtitle: subtitle,
            url: url,
            bundleIdentifier: bundleIdentifier
        )
    }

    private enum CodingKeys: String, CodingKey {
        case identity, path, kind, title, subtitle, bundleIdentifier, addedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let path = try c.decode(String.self, forKey: .path)
        self.path = path
        kind = try c.decodeIfPresent(QuickSearchResult.Kind.self, forKey: .kind) ?? .file
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? (path as NSString).lastPathComponent
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? (path as NSString).deletingLastPathComponent
        bundleIdentifier = try c.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date(timeIntervalSince1970: 0)
        identity = try c.decodeIfPresent(String.self, forKey: .identity)
            ?? QuickSearchUsageStore.identity(bundleIdentifier: bundleIdentifier, path: path)
    }
}

/// 收藏集合的规则：加进去、去掉、以及空查询时那一屏怎么排。全是纯函数。
enum QuickSearchFavorites {
    /// 加入收藏。已存在时保持原位与原始时刻——重复收藏不是「挪到最后」。
    static func add(
        _ favorite: QuickSearchFavorite,
        to favorites: [QuickSearchFavorite],
        limit: Int
    ) -> [QuickSearchFavorite] {
        guard !favorites.contains(where: { $0.identity == favorite.identity }) else { return favorites }
        var updated = favorites
        updated.append(favorite)
        if updated.count > max(0, limit) {
            // 满了丢最早加入的那一条：用户后来钉住的东西更有价值。
            updated = Array(updated.suffix(max(0, limit)))
        }
        return updated
    }

    static func remove(identity: String, from favorites: [QuickSearchFavorite]) -> [QuickSearchFavorite] {
        favorites.filter { $0.identity != identity }
    }

    static func contains(identity: String, in favorites: [QuickSearchFavorite]) -> Bool {
        favorites.contains { $0.identity == identity }
    }

    /// 收藏行的顺序：打开次数多的在前，次数相同按加入收藏的先后。
    /// 与搜索结果的排序规则一致，收藏列表才不会看着像另一套逻辑。
    static func ordered(
        _ favorites: [QuickSearchFavorite],
        usageCount: (QuickSearchFavorite) -> Int
    ) -> [QuickSearchFavorite] {
        favorites.sorted { lhs, rhs in
            let left = usageCount(lhs)
            let right = usageCount(rhs)
            if left != right { return left > right }
            if lhs.addedAt != rhs.addedAt { return lhs.addedAt < rhs.addedAt }
            return lhs.identity < rhs.identity
        }
    }

    /// 空查询那一屏：收藏在前，最近使用在后，同一条只出现一次；
    /// 还有空位就按索引里的名称顺序补齐——没搜过的应用也要能直接启动，
    /// 而不是只让用户看见最近用过的几个。
    static func rows(
        favorites: [QuickSearchFavorite],
        entries: [QuickSearchApplicationEntry],
        recent: [QuickSearchResult],
        favoriteLimit: Int,
        totalLimit: Int
    ) -> [QuickSearchResult] {
        let index = Dictionary(
            entries.map { ($0.usageIdentity, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seen: Set<String> = []
        var picked: [QuickSearchResult] = []
        for favorite in favorites.prefix(max(0, favoriteLimit)) {
            guard seen.insert(favorite.identity).inserted else { continue }
            if let entry = index[favorite.identity] {
                picked.append(QuickSearchResult(application: entry))
            } else {
                picked.append(favorite.result)
            }
        }
        for result in recent {
            guard picked.count < max(0, totalLimit) else { break }
            let identity = QuickSearchUsageStore.identity(
                bundleIdentifier: result.bundleIdentifier,
                path: result.url.standardizedFileURL.path
            )
            guard seen.insert(identity).inserted else { continue }
            picked.append(result)
        }
        for entry in entries {
            guard picked.count < max(0, totalLimit) else { break }
            // Finder 都不显示的备份包（`.NAME.app`）不该占空查询的名额；
            // 它们仍然可以靠输入名称搜到。
            guard !entry.url.lastPathComponent.hasPrefix(".") else { continue }
            guard seen.insert(entry.usageIdentity).inserted else { continue }
            picked.append(QuickSearchResult(application: entry))
        }
        return picked
    }
}

extension QuickSearchResult {
    /// 这一行在收藏里的键。与 `QuickSearchFavorite.identity` 同一套算法，
    /// 所以收藏判断不受搜索结果顺序或来源影响。
    var favoriteIdentity: String {
        QuickSearchUsageStore.identity(
            bundleIdentifier: bundleIdentifier,
            path: url.standardizedFileURL.path
        )
    }
}

extension QuickSearchResult {
    init(application entry: QuickSearchApplicationEntry, matchedTagTerms: [String] = []) {
        self.init(
            kind: .application,
            title: entry.name,
            subtitle: entry.directoryDisplayName,
            url: entry.url,
            bundleIdentifier: entry.bundleIdentifier,
            matchedTagTerms: matchedTagTerms
        )
    }
}
