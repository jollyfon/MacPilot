//
//  ApplicationSearchProvider.swift
//  MacPilot
//
//  在已建好的应用索引上做匹配与排序。纯函数、不碰磁盘、不碰 AppKit，
//  所以可以直接在测试里喂假索引。
//

import Foundation

enum ApplicationSearchProvider {
    /// 搜索应用。`usage` 是同目录下的使用次数查询，用于同级匹配的先后。
    /// `includeTags` 打开后，名称完全没对上的应用还能按用途标签命中，
    /// 排在所有名称命中之后。
    static func search(
        query: String,
        entries: [QuickSearchApplicationEntry],
        usage: (QuickSearchApplicationEntry) -> Int = { _ in 0 },
        includeTags: Bool,
        limit: Int
    ) -> [QuickSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var candidates: [QuickSearchRankedResult<QuickSearchApplicationEntry>] = []
        candidates.reserveCapacity(entries.count)
        for entry in entries {
            guard let match = QuickSearchMatcher.match(query: trimmed, fields: entry.fields, includeTags: includeTags) else { continue }
            candidates.append(
                QuickSearchRankedResult(
                    value: entry,
                    match: match,
                    usageCount: usage(entry),
                    stableName: entry.name,
                    stablePath: entry.path
                )
            )
        }
        return QuickSearchRanking.rank(candidates, limit: limit).map {
            QuickSearchResult(application: $0.value, matchedTagTerms: $0.match.matchedTags)
        }
    }

    /// 空查询时按「最近使用」展示。只列仍在索引里的应用——卸载后不再出现。
    static func recentApplications(
        entries: [QuickSearchApplicationEntry],
        recentIdentities: [String],
        limit: Int
    ) -> [QuickSearchResult] {
        let index = Dictionary(
            entries.map { ($0.usageIdentity, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var picked: [QuickSearchApplicationEntry] = []
        picked.reserveCapacity(recentIdentities.count)
        for identity in recentIdentities {
            if let entry = index[identity] { picked.append(entry) }
            if picked.count >= max(0, limit) { break }
        }
        return picked.map { QuickSearchResult(application: $0) }
    }
}

extension QuickSearchApplicationEntry {
    /// 与 `QuickSearchUsageStore` 一致的归并键。
    var usageIdentity: String {
        QuickSearchUsageStore.identity(bundleIdentifier: bundleIdentifier, path: path)
    }
}
