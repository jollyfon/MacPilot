//
//  QuickSearchAppTags.swift
//  MacPilot
//
//  应用的「用途」标签，只用来让「图片」「下载」这类说法能搜到对应软件。
//
//  Mac 上的 .app 里**没有**人能读懂的用途描述：App Store 的简介在服务器上，
//  Spotlight 对应用包给出的 kMDItemDescription / kMDItemKeywords 实测基本是空的
//  （见 SUMMARY.md）。所以标签只能来自厂商自己在 Info.plist 里写下的三类声明：
//  分类（LSApplicationCategoryType）、URL 方案（CFBundleURLTypes）、
//  文档类型（CFBundleDocumentTypes）。三者都是「厂商声明了才算」——
//  没声明的应用就没有标签，绝不按名字猜用途，也绝不联网取元数据。
//
//  全部是纯函数、只在建索引时跑一次，输入时不再读盘。
//

import Foundation

/// 一个应用包里与用途有关的声明。缺失的项就是空数组，不做推断。
struct QuickSearchAppMetadata: Sendable, Equatable {
    let categoryType: String
    let urlSchemes: [String]
    let contentTypes: [String]

    init(categoryType: String = "", urlSchemes: [String] = [], contentTypes: [String] = []) {
        self.categoryType = categoryType
        self.urlSchemes = urlSchemes
        self.contentTypes = contentTypes
    }
}

enum QuickSearchAppTagger {
    /// 单个应用最多带几个标签：再多就只是把命中行塞满噪声。
    static let maximumTagsPerApp = 6

    /// 分类 → 用途词。`public.app-category.utilities` 与 `productivity` 被厂商当作
    /// 「其余一切」的垃圾桶用（本机 202 个应用里各占 38 与 27 个），说了等于没说，
    /// 所以刻意不出现在这里。
    private static let categoryTags: [String: [String]] = [
        "public.app-category.photography": ["图片", "照片", "photo", "image"],
        "public.app-category.graphics-design": ["设计", "作图", "design"],
        "public.app-category.video": ["视频", "影音", "video"],
        "public.app-category.music": ["音乐", "音频", "music", "audio"],
        "public.app-category.entertainment": ["影音", "娱乐"],
        "public.app-category.games": ["游戏", "game"],
        "public.app-category.social-networking": ["聊天", "社交", "chat", "social"],
        "public.app-category.developer-tools": ["开发", "代码", "编程", "code", "develop"],
        "public.app-category.business": ["办公", "企业", "office"],
        "public.app-category.reference": ["资料", "文档", "reference"],
        "public.app-category.education": ["学习", "教育", "study"],
        "public.app-category.news": ["新闻", "资讯", "news"],
        "public.app-category.finance": ["财务", "记账", "finance"],
        "public.app-category.health-and-fitness": ["健康", "运动", "fitness"],
        "public.app-category.travel": ["旅行", "travel"],
        "public.app-category.navigation": ["地图", "导航", "map", "navigation"],
        "public.app-category.weather": ["天气", "weather"],
        "public.app-category.food-and-drink": ["美食", "餐饮"],
        "public.app-category.shopping": ["购物", "shopping"],
        "public.app-category.sports": ["体育", "运动", "sports"],
        "public.app-category.medical": ["医疗", "medical"],
        "public.app-category.childrens": ["儿童", "kids"],
    ]

    /// 注册了这些 URL 方案，就说明它真的处理这类链接。
    /// 顺序即优先级：下载器最典型，放最前。
    private static let schemeRules: [(exact: Set<String>, tags: [String])] = [
        (["magnet", "ed2k", "thunder", "flashget", "qqdl", "btih", "aria2"], ["下载", "download"]),
        (["http", "https"], ["浏览器", "browser"]),
        (["ftp", "sftp", "scp", "ssh", "vnc", "rdp", "mstsc", "telnet"], ["远程", "传输", "remote"]),
        (["weixin", "weixinapp", "mqq", "mqqapi", "tencent", "qqopenapi", "dingtalk",
          "tg", "telegram", "whatsapp", "slack", "discord", "skype"], ["聊天", "社交", "chat"]),
        (["postgres", "postgresql", "mysql", "mssql", "oracle", "mongodb", "redis",
          "mariadb", "clickhouse", "sqlite", "sqlite3"], ["数据库", "database"]),
        (["webcal", "caldav"], ["日历", "calendar"]),
    ]

    /// 文档类型按 UTI 前缀判断：同一族的后缀太多，逐个列举必然漏。
    /// `public.folder`、`com.apple.package`、`com.apple.application-bundle` 这类
    /// 每个应用都会声明的样板不在表里，所以不会被当成用途。
    private static let contentTypeRules: [(prefixes: [String], tags: [String])] = [
        (["public.image", "public.jpeg", "public.png", "public.tiff", "public.heic",
          "public.heif", "public.raw-image", "public.svg", "public.bitmap", "public.webp",
          "com.compuserve.gif", "com.adobe.photoshop-image", "com.adobe.illustrator.ai-image",
          "com.apple.icns"], ["图片", "photo"]),
        (["public.movie", "public.mpeg", "public.avi", "public.matroska", "public.video",
          "public.quicktime", "com.apple.quicktime", "com.microsoft.asf"], ["视频", "video"]),
        (["public.audio", "public.mp3", "public.mpeg-4-audio", "public.aiff", "public.wav",
          "com.apple.mp4-audio", "public.mid"], ["音频", "music"]),
        (["com.adobe.pdf", "public.pdf"], ["pdf", "文档"]),
        (["public.zip-archive", "public.arc-archive", "public.composite-archive",
          "public.tar", "public.gzip", "public.bzip2", "public.xz", "org.gnu.gnu-zip",
          "public.rar", "com.rarlab"], ["压缩", "archive"]),
        (["com.apple.iwork", "com.microsoft.word", "com.microsoft.excel", "com.microsoft.powerpoint",
          "com.apple.pages", "com.apple.numbers", "com.apple.keynote", "openxmlformats"], ["办公", "office"]),
        (["com.apple.photos", "public.photo-library", "public.photos"], ["照片", "图库"]),
        (["public.epub", "com.apple.iBooks", "public.audible-content"], ["电子书", "阅读"]),
        (["public.plain-text", "public.source-code", "public.script", "public.xml",
          "public.json", "public.yaml"], ["文本", "代码", "text"]),
    ]

    /// 由声明推出标签。返回顺序稳定：URL 方案（最强的行为证据）→ 文档类型 → 分类。
    static func tags(for metadata: QuickSearchAppMetadata) -> [String] {
        var collected: [String] = []
        var seen = Set<String>()

        func append(_ candidates: [String]) {
            for tag in candidates where seen.insert(QuickSearchTextNormalizer.fold(tag)).inserted {
                collected.append(tag)
            }
        }

        let schemes = Set(metadata.urlSchemes.map { QuickSearchTextNormalizer.fold($0) })
        for rule in schemeRules where !rule.exact.isDisjoint(with: schemes) {
            append(rule.tags)
        }

        // 注册了 http/https 的应用是「通用处理器」：它还声明能打开图片、视频、PDF，
        // 只说明它什么都能打开，不说明它是图片工具。本机 Chrome、Edge、Firefox、Claude
        // 都因此挤进「图片」结果里。它们自己的答案在「浏览器」那一档。
        let isGeneralHandler = schemes.contains("http") || schemes.contains("https")
        if !isGeneralHandler {
            for rule in contentTypeRules {
                guard metadata.contentTypes.contains(where: { type in
                    let folded = QuickSearchTextNormalizer.fold(type)
                    return rule.prefixes.contains { folded.hasPrefix($0) }
                }) else { continue }
                append(rule.tags)
            }
        }

        if let category = categoryTags[QuickSearchTextNormalizer.fold(metadata.categoryType)] {
            append(category)
        }

        return Array(collected.prefix(maximumTagsPerApp))
    }
}

/// 从应用包里读出用途声明与别名。只在后台扫描时调用。
enum QuickSearchAppInfoReader {
    struct Info: Sendable, Equatable {
        let metadata: QuickSearchAppMetadata
        /// 与 Finder 显示名不同的其他叫法：Info.plist 里未本地化的名字、包目录名。
        /// 用户可能用任意一种来搜（迅雷的包名是 Thunder，本地化显示名是 迅雷）。
        let alternateNames: [String]
    }

    /// 直接读 `Contents/Info.plist`，不走 `Bundle` 的进程内缓存——和
    /// `InstalledAppResolver.freshVersion` 同一个理由：原地升级后要看到新值。
    static func read(fromAppAt url: URL) -> Info {
        let plistURL = url.appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            return Info(metadata: QuickSearchAppMetadata(), alternateNames: [])
        }

        var names: [String] = []
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let value = plist[key] as? String, !value.trimmingCharacters(in: .whitespaces).isEmpty {
                names.append(value)
            }
        }
        names.append(url.deletingPathExtension().lastPathComponent)

        return Info(
            metadata: QuickSearchAppMetadata(
                categoryType: plist["LSApplicationCategoryType"] as? String ?? "",
                urlSchemes: collect(plist["CFBundleURLTypes"], under: "CFBundleURLSchemes"),
                contentTypes: collect(plist["CFBundleDocumentTypes"], under: "LSItemContentTypes")
            ),
            alternateNames: names
        )
    }

    /// `[[String: Any]]` 里取出某个字符串数组字段并合并；结构不对就当没有。
    private static func collect(_ value: Any?, under key: String) -> [String] {
        guard let entries = value as? [[String: Any]] else { return [] }
        return entries.flatMap { ($0[key] as? [String]) ?? [] }
    }
}
