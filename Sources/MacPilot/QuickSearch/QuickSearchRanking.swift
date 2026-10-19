//
//  QuickSearchRanking.swift
//  MacPilot
//
//  文本归一化（含中文拼音）与匹配分级、排序。全部是纯函数：
//  拼音在**建索引时**算一次存进搜索字段，输入时不再重复转换；
//  模糊匹配只用子序列，不做全量编辑距离。
//
//  可搜索形式有两种：应用的各个名称（含未本地化的包名），以及开关打开后的
//  用途标签。名称永远排在标签之前。
//

import Foundation

// MARK: - 搜索字段

/// 一个名字在索引阶段算好的归一化形式。
struct QuickSearchNameFields: Sendable, Equatable {
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

/// 一个用途标签：折叠形式用来比对，原样用来在行上解释「为什么出现这一条」。
struct QuickSearchTagTerm: Sendable, Equatable {
    let display: String
    let folded: String

    init(_ display: String) {
        self.display = display
        // 标签与关键词按「只留字母数字」比对：`AI Agent` 与 `aiagent` 是同一个词，
        // 用户输入里的空格/连字符不该决定命中与否。
        self.folded = QuickSearchTextNormalizer.compact(display)
    }
}

/// 一条结果在索引阶段算好的全部可搜索形式：名称的各个叫法 + 用途标签 + 描述关键词。
struct QuickSearchSearchFields: Sendable, Equatable {
    /// 名称字段，第一个就是列表里显示的那个。同一个应用往往有两个名字：Finder
    /// 显示的是本地化过的（迅雷），`Info.plist` 里还写着未本地化的（Thunder）。
    /// 只索引其中一个，用户按另一个叫法就搜不到。
    let names: [QuickSearchNameFields]
    /// 用途标签。空数组表示这个应用什么标签都没有——不代表它没有用途，
    /// 只是厂商没在 `Info.plist` 里声明过，我们不猜。
    let tags: [QuickSearchTagTerm]
    /// 厂商写在描述、菜单名或 package.json 里的词，以及词表给出的中英互译。
    /// 这些词只在名称和用途标签都没命中时才参与排序。
    let keywords: [QuickSearchTagTerm]
    /// 描述原文的紧凑形式（去空格与标点），用于中文短语的包含匹配。
    let compactDescription: String

    init(
        title: String,
        alternateTitles: [String] = [],
        tags: [String] = [],
        description: String = "",
        extraKeywords: [String] = []
    ) {
        var built: [QuickSearchNameFields] = []
        var seen = Set<String>()
        for candidate in [title] + alternateTitles {
            let fields = QuickSearchNameFields(title: candidate)
            guard !fields.foldedTitle.isEmpty, seen.insert(fields.foldedTitle).inserted else { continue }
            built.append(fields)
        }
        names = built
        let tagTerms = tags.map(QuickSearchTagTerm.init).filter { !$0.folded.isEmpty }
        self.tags = tagTerms
        let tagFolded = Set(tagTerms.map(\.folded))
        let derived = QuickSearchKeywordLexicon.keywords(from: tags + [description])
        keywords = QuickSearchKeywordLexicon
            .merging(derived, with: extraKeywords)
            .filter { !tagFolded.contains(QuickSearchTextNormalizer.compact($0)) }
            .map(QuickSearchTagTerm.init)
            .filter { !$0.folded.isEmpty }
        compactDescription = String(
            QuickSearchTextNormalizer.compact(description).prefix(400)
        )
    }

    /// 主名称的折叠形式。
    var foldedTitle: String { names.first?.foldedTitle ?? "" }
    var pinyinFull: String? { names.first?.pinyinFull }
    var pinyinInitials: String? { names.first?.pinyinInitials }
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

    /// 只留下字母与数字。标签、关键词、描述短语都用这个形式比对。
    static func compact(_ string: String) -> String {
        String(fold(string).filter { $0.isLetter || $0.isNumber })
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
    /// 名称一个字母都没对上，但用途标签对上了。排在所有名称命中之后：
    /// 用户要的是名字里带「图」的软件，不是所有被标成「图片」的软件。
    case tag = 6
    case fuzzy = 7
    /// 只有厂商写的描述命中。它比模糊名称还弱：名字哪怕只对上几个字母，
    /// 也比「描述里提过这个词」更可能指向用户要找的应用。
    case keyword = 8

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct QuickSearchMatch: Sendable, Equatable {
    let tier: QuickSearchMatchTier
    /// 匹配起点，越靠前越好。
    let position: Int
    /// 模糊匹配跨过的字符数；非模糊为 0。
    let gap: Int
    /// 仅 `.tag` / `.keyword` 等级有值：命中的标签或描述词，用来在行上说明命中原因。
    var matchedTags: [String] = []
}

enum QuickSearchMatcher {
    /// 一次输入是否只含 ASCII 字母数字。含中文的查询不该再去比拼音首字母。
    private static func isASCIIALNumeric(_ string: String) -> Bool {
        !string.isEmpty && string.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 122)
        }
    }

    /// 用途标签最短要几个字符才参与匹配：单字母会把一整类软件全捞出来。
    static let minimumTagQueryCharacters = 2
    /// 拉丁前缀至少几个字符才允许「标签以输入开头」这条路。
    /// 两个字母的 `co`/`of`/`ch` 能前缀命中 code/office/chat，等于把三大类
    /// 软件全端上来，那是噪声不是搜索。三个字母起（`cha`→chat）已经足够指认。
    static let minimumLatinTagPrefixCharacters = 3

    /// 名称与用途的全部命中里取最好的一个。
    ///
    /// 每个名称变体都要试：只看显示名的话，「迅雷」就再也搜不到 Thunder。
    static func match(
        query: String,
        fields: QuickSearchSearchFields,
        includeTags: Bool
    ) -> QuickSearchMatch? {
        let needle = fold(query)
        guard !needle.isEmpty else { return nil }
        let compactNeedle = QuickSearchTextNormalizer.compact(query)

        var best: QuickSearchMatch?
        for name in fields.names {
            guard let hit = nameMatch(needle: needle, name: name) else { continue }
            if best == nil || isBetter(hit, than: best!) { best = hit }
        }
        if includeTags, let hit = tagMatch(needle: compactNeedle, tags: fields.tags),
           best == nil || isBetter(hit, than: best!) {
            best = hit
        }
        if includeTags, let hit = keywordMatch(needle: compactNeedle, query: query, fields: fields),
           best == nil || isBetter(hit, than: best!) {
            best = hit
        }
        return best
    }

    private static func isBetter(_ lhs: QuickSearchMatch, than rhs: QuickSearchMatch) -> Bool {
        if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
        if lhs.position != rhs.position { return lhs.position < rhs.position }
        return lhs.gap < rhs.gap
    }

    private static func nameMatch(needle: String, name: QuickSearchNameFields) -> QuickSearchMatch? {
        let haystack = name.foldedTitle
        guard !haystack.isEmpty else { return nil }

        if haystack == needle { return QuickSearchMatch(tier: .exact, position: 0, gap: 0) }
        if haystack.hasPrefix(needle) { return QuickSearchMatch(tier: .prefix, position: 0, gap: 0) }
        if let tokenPosition = firstTokenPrefixPosition(needle: needle, tokens: name.foldedTokens) {
            return QuickSearchMatch(tier: .tokenPrefix, position: tokenPosition, gap: 0)
        }
        if let range = haystack.range(of: needle) {
            let offset = haystack.distance(from: haystack.startIndex, to: range.lowerBound)
            return QuickSearchMatch(tier: .contains, position: offset, gap: 0)
        }

        // 拼音分支只在拉丁输入上做：中文输入已经命中上面的普通匹配。
        if isASCIIALNumeric(needle) {
            if let full = name.pinyinFull, full.hasPrefix(needle) {
                return QuickSearchMatch(tier: .pinyinPrefix, position: 0, gap: 0)
            }
            if let initials = name.pinyinInitials, initials.hasPrefix(needle) {
                return QuickSearchMatch(tier: .pinyinInitials, position: 0, gap: 0)
            }
        }

        // 轻量模糊：查询字符按顺序出现即可，记录跨过的字符数作为代价。
        return subsequenceMatch(needle: needle, haystack: haystack)
    }

    /// 标签匹配只看前缀互含：「下」→「下载」不算（太短），「下载器」算命中，
    /// 但标签的拼音不参与——输 `tu` 就把每个图片类软件捞出来是噪声，不是搜索。
    private static func tagMatch(needle: String, tags: [QuickSearchTagTerm]) -> QuickSearchMatch? {
        guard needle.count >= minimumTagQueryCharacters, !tags.isEmpty else { return nil }
        let allowPrefixHit = !isASCIIALNumeric(needle) || needle.count >= minimumLatinTagPrefixCharacters
        let hit = tags.filter { term in
            if term.folded == needle || needle.hasPrefix(term.folded) { return true }
            return allowPrefixHit && term.folded.hasPrefix(needle)
        }
        guard !hit.isEmpty else { return nil }
        return QuickSearchMatch(
            tier: .tag,
            position: 0,
            gap: 0,
            matchedTags: hit.map(\.display)
        )
    }

    /// 描述关键词比用途标签更弱：标签是厂商声明的用途，描述只是提到过。
    /// 中文短语还可以直接落在描述原文里；拉丁输入不这么做，
    /// 否则 `ai` 会在 `said`/`email` 里到处命中。
    private static func keywordMatch(
        needle: String,
        query: String,
        fields: QuickSearchSearchFields
    ) -> QuickSearchMatch? {
        guard needle.count >= minimumTagQueryCharacters else { return nil }
        let allowPrefixHit = !isASCIIALNumeric(needle) || needle.count >= minimumLatinTagPrefixCharacters
        // quality：0 = 词完全相等，1 = 查询是词的延伸（下载器 → 下载），
        // 2 = 词以查询开头。行上的说明优先显示最精确的那个词。
        var hits: [(quality: Int, position: Int, display: String)] = []
        for (index, term) in fields.keywords.enumerated() {
            if term.folded == needle {
                hits.append((0, index, term.display))
            } else if needle.hasPrefix(term.folded) {
                hits.append((1, index, term.display))
            } else if allowPrefixHit, term.folded.hasPrefix(needle) {
                hits.append((2, index, term.display))
            }
        }
        if hits.isEmpty,
           needle.rangeOfCharacter(from: QuickSearchTextNormalizer.hanCharacters) != nil,
           fields.compactDescription.contains(needle) {
            return QuickSearchMatch(
                tier: .keyword,
                position: 0,
                gap: 0,
                matchedTags: [query.trimmingCharacters(in: .whitespacesAndNewlines)]
            )
        }
        guard !hits.isEmpty else { return nil }
        hits.sort { lhs, rhs in
            lhs.quality != rhs.quality ? lhs.quality < rhs.quality : lhs.position < rhs.position
        }
        return QuickSearchMatch(
            tier: .keyword,
            position: hits[0].position,
            gap: 0,
            matchedTags: hits.map(\.display)
        )
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
    /// 历史打开次数，**排序的第一依据**：同一个查询下用过多次的排在前。
    let usageCount: Int
    /// 稳定次序用的名称与路径。
    let stableName: String
    let stablePath: String
}

enum QuickSearchRanking {
    /// 声明顺序即优先级：使用频率 → 匹配程度 → 位置 → 代价 → 稳定次序。
    ///
    /// 频率在匹配程度之前是有意的：输入「abc」出来一排同名候选时，用户要的是
    /// 那一个被反复打开的，不是名字里字母排得最正的。次数相同才回头比匹配质量，
    /// 所以从没用过的东西依然按名字排。
    static func orderedByRelevance<Value>(
        _ lhs: QuickSearchRankedResult<Value>,
        _ rhs: QuickSearchRankedResult<Value>
    ) -> Bool {
        if lhs.usageCount != rhs.usageCount { return lhs.usageCount > rhs.usageCount }
        if lhs.match.tier != rhs.match.tier { return lhs.match.tier < rhs.match.tier }
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

/// 只按打开次数排序，其余顺序原样保留。
///
/// Spotlight 回来的文件顺序已经是它自己的相关性排序，这里没有名称分级可比，
/// 所以规则是「打开过的提到前面，次数相同保持 Spotlight 的顺序」。显式带上
/// 下标做次级键，因为 Swift 的 `sorted` 不保证稳定。
enum QuickSearchFrequencyOrder {
    static func ordered<Value>(
        _ values: [Value],
        usageCount: (Value) -> Int
    ) -> [Value] {
        values.enumerated()
            .sorted { lhs, rhs in
                let left = usageCount(lhs.element)
                let right = usageCount(rhs.element)
                if left != right { return left > right }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
