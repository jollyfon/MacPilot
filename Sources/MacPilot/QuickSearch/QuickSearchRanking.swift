//
//  QuickSearchRanking.swift
//  MacPilot
//
//  文本归一化（含中文拼音）与匹配分级、排序。全部是纯函数：
//  拼音在**建索引时**算一次存进搜索字段，输入时不再重复转换；
//  模糊匹配只用子序列，不做全量编辑距离。
//

import Foundation

// MARK: - 搜索字段

/// 一条可搜索名称在索引阶段算好的归一化形式。
struct QuickSearchSearchFields: Sendable, Equatable {
    /// 小写、去音调后的完整名称。
    let foldedTitle: String
    /// 按空白切出的词，同样已折叠。
    let foldedTokens: [String]
    /// 全拼（去空格、去音调），例如「计算器」→ `jisuanqi`。纯拉丁名也给出，
    /// 这样 `safari` 这类英文名不会因为「不是中文」而少一层匹配。
    let pinyinFull: String?
    /// 首字母，例如「计算器」→ `jsq`。
    let pinyinInitials: String?

    init(title: String) {
        let folded = QuickSearchTextNormalizer.fold(title)
        foldedTitle = folded
        foldedTokens = folded.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" }).map(String.init)
        let variants = QuickSearchTextNormalizer.pinyinVariants(of: title)
        pinyinFull = variants.full
        pinyinInitials = variants.initials
    }
}

enum QuickSearchTextNormalizer {
    /// CJK 统一表意文字（基本区 + 扩展 A）。用于判断名称里是否可能有中文读音。
    static let hanCharacters = CharacterSet(charactersIn:
        Unicode.Scalar(0x4E00)!...Unicode.Scalar(0x9FFF)!
    ).union(CharacterSet(charactersIn: Unicode.Scalar(0x3400)!...Unicode.Scalar(0x4DBF)!))

    /// 小写 + 去音调。搜索侧和被搜索侧都走这里，两边才能对得上。
    static func fold(_ string: String) -> String {
        let lowercased = string.lowercased()
        return lowercased.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "\u{0}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 汉字 → 拉丁（去音调），返回全拼与首字母。
    ///
    /// 走系统 `CFStringTransform`，不引入第三方拼音表。转换失败或名称里没有
    /// 汉字时返回 nil，调用方按「没有拼音字段」处理。
    static func pinyinVariants(of string: String) -> (full: String?, initials: String?) {
        guard string.rangeOfCharacter(from: hanCharacters) != nil else {
            // 纯拉丁名：仍给一份折叠结果，让前缀/首字母匹配对英文名同样成立。
            let folded = fold(string)
            let tokens = folded.split(separator: " ").map(String.init)
            guard !tokens.isEmpty else { return (nil, nil) }
            let initials = tokens.compactMap { $0.first }.map(String.init).joined()
            return (folded.replacingOccurrences(of: " ", with: ""), initials.count > 1 ? initials : nil)
        }

        let mutable = NSMutableString(string: string)
        var range = CFRangeMake(0, mutable.length)
        guard CFStringTransform(mutable, &range, kCFStringTransformMandarinLatin, false) else { return (nil, nil) }
        CFStringTransform(mutable, &range, kCFStringTransformStripDiacritics, false)
        let latin = fold(mutable as String).replacingOccurrences(of: "　", with: " ")
        let tokens = latin.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return (nil, nil) }
        let full = tokens.joined()
        let initials = tokens.compactMap { $0.first }.map(String.init).joined()
        return (full, initials.count > 1 ? initials : nil)
    }
}

// MARK: - 匹配分级

/// 匹配质量等级，数值越小越好。
enum QuickSearchMatchTier: Int, Comparable, Sendable {
    case exact = 0
    case prefix = 1
    case tokenPrefix = 2
    case contains = 3
    case pinyinPrefix = 4
    case pinyinInitials = 5
    case fuzzy = 6

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct QuickSearchMatch: Sendable, Equatable {
    let tier: QuickSearchMatchTier
    /// 匹配起点，越靠前越好。
    let position: Int
    /// 模糊匹配跨过的字符数；非模糊为 0。
    let gap: Int
}

enum QuickSearchMatcher {
    /// 一次输入是否只含 ASCII 字母数字。含中文的查询不该再去比拼音首字母。
    private static func isASCIIALNumeric(_ string: String) -> Bool {
        !string.isEmpty && string.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 122)
        }
    }

    static func match(query: String, fields: QuickSearchSearchFields) -> QuickSearchMatch? {
        let needle = fold(query)
        guard !needle.isEmpty else { return nil }
        let haystack = fields.foldedTitle
        guard !haystack.isEmpty else { return nil }

        if haystack == needle { return QuickSearchMatch(tier: .exact, position: 0, gap: 0) }
        if haystack.hasPrefix(needle) { return QuickSearchMatch(tier: .prefix, position: 0, gap: 0) }
        if let tokenPosition = firstTokenPrefixPosition(needle: needle, tokens: fields.foldedTokens) {
            return QuickSearchMatch(tier: .tokenPrefix, position: tokenPosition, gap: 0)
        }
        if let range = haystack.range(of: needle) {
            let offset = haystack.distance(from: haystack.startIndex, to: range.lowerBound)
            return QuickSearchMatch(tier: .contains, position: offset, gap: 0)
        }

        // 拼音分支只在拉丁输入上做：中文输入已经命中上面的普通匹配。
        if isASCIIALNumeric(needle) {
            if let full = fields.pinyinFull, full.hasPrefix(needle) {
                return QuickSearchMatch(tier: .pinyinPrefix, position: 0, gap: 0)
            }
            if let initials = fields.pinyinInitials, initials.hasPrefix(needle) {
                return QuickSearchMatch(tier: .pinyinInitials, position: 0, gap: 0)
            }
        }

        // 轻量模糊：查询字符按顺序出现即可，记录跨过的字符数作为代价。
        if let fuzzy = subsequenceMatch(needle: needle, haystack: haystack) {
            return fuzzy
        }
        return nil
    }

    private static func fold(_ string: String) -> String {
        // 搜索词里的空格对用户没有区分意义（"google chrome" ≈ "googlechrome"）。
        QuickSearchTextNormalizer.fold(string).replacingOccurrences(of: " ", with: "")
    }

    private static func firstTokenPrefixPosition(needle: String, tokens: [String]) -> Int? {
        var offset = 0
        for token in tokens {
            if token.hasPrefix(needle) { return offset }
            offset += token.count + 1
        }
        return nil
    }

    private static func subsequenceMatch(needle: String, haystack: String) -> QuickSearchMatch? {
        guard needle.count >= 2, haystack.count >= needle.count else { return nil }
        let characters = Array(haystack)
        var searchIndex = 0
        var firstHit: Int?
        var lastHit = 0
        for (position, character) in characters.enumerated() {
            guard character == needle[needle.index(needle.startIndex, offsetBy: searchIndex)] else { continue }
            if firstHit == nil { firstHit = position }
            lastHit = position
            searchIndex += 1
            if searchIndex == needle.count { break }
        }
        guard searchIndex == needle.count, let start = firstHit else { return nil }
        // 只有紧凑的子序列才算模糊命中：跨半个名字的散点匹配噪声太大。
        let span = lastHit - start + 1
        guard span <= needle.count * 3 else { return nil }
        return QuickSearchMatch(tier: .fuzzy, position: start, gap: span - needle.count)
    }
}

// MARK: - 排序

/// 一条结果的排序键。携带原值与评分依据，排序与截断一次完成。
struct QuickSearchRankedResult<Value: Sendable>: Sendable {
    let value: Value
    let match: QuickSearchMatch
    /// 历史使用次数，同级匹配时高者在前。
    let usageCount: Int
    /// 稳定次序用的名称与路径。
    let stableName: String
    let stablePath: String
}

enum QuickSearchRanking {
    /// 声明顺序即优先级：匹配程度 → 使用频率 → 位置 → 代价 → 稳定次序。
    static func orderedByRelevance<Value>(
        _ lhs: QuickSearchRankedResult<Value>,
        _ rhs: QuickSearchRankedResult<Value>
    ) -> Bool {
        if lhs.match.tier != rhs.match.tier { return lhs.match.tier < rhs.match.tier }
        if lhs.usageCount != rhs.usageCount { return lhs.usageCount > rhs.usageCount }
        if lhs.match.position != rhs.match.position { return lhs.match.position < rhs.match.position }
        if lhs.match.gap != rhs.match.gap { return lhs.match.gap < rhs.match.gap }
        let nameOrder = lhs.stableName.localizedCaseInsensitiveCompare(rhs.stableName)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return lhs.stablePath < rhs.stablePath
    }

    /// 排序并按条数截断。`limit` 只限制展示量，不限制参与评分的候选数。
    static func rank<Value>(
        _ candidates: [QuickSearchRankedResult<Value>],
        limit: Int
    ) -> [QuickSearchRankedResult<Value>] {
        let sorted = candidates.sorted(by: orderedByRelevance)
        guard limit >= 0 else { return sorted }
        return Array(sorted.prefix(limit))
    }
}
