//
//  QuickSearchKeywordLexicon.swift
//  MacPilot
//
//  软件自己写下的描述与关键词，需要能按中英文互相搜到。
//
//  这里只做「词表展开」，不翻译自由文本：厂商在应用包里写下 AI、agent、
//  uninstall 或「清理」这类词时，同一个概念的另一种语言说法也一起进索引。
//  词表固定、离线、可预测；没有网络请求，也不调用系统翻译服务。
//
//  两条边界：
//  1. 概念由描述里的原词触发，绝不凭应用名或分类猜用途；
//  2. 原始描述词只取有意义的 token，停用词（app、desktop、application…）
//     不进索引，避免每个应用都被同样的泛词搜到。
//

import Foundation

/// 一个双向词概念：任意一个 trigger 出现在厂商描述里，整组 terms 都可以搜到。
struct QuickSearchKeywordConcept: Sendable {
    let triggers: [String]
    let terms: [String]
}

enum QuickSearchKeywordLexicon {
    /// 单个应用最多带多少描述关键词。再多只是把候选池灌满噪声。
    static let maximumKeywordTerms = 28

    /// 描述里常见、但不能说明用途的词。它们不进入关键词索引。
    private static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "for", "with", "from", "your", "you",
        "our", "their", "this", "that", "these", "those", "all", "any", "can",
        "will", "get", "set", "into", "out", "about", "more", "most", "other",
        "than", "then", "when", "where", "which", "while", "who", "why", "how",
        "app", "apps", "application", "applications", "desktop", "mac", "macos",
        "os", "software", "tool", "tools", "utility", "utilities", "platform",
        "version", "free", "pro", "premium", "trial", "beta", "new", "easy",
        "powerful", "best", "simple", "modern", "use", "using", "used", "make",
        "makes", "made", "work", "works", "working", "manage", "manager",
        "management", "file", "files", "data", "system", "systems", "feature",
        "features", "support", "supports", "supported", "based", "built",
        "create", "creates", "creating", "user", "users", "people", "time",
        "way", "thing", "things", "need", "needs", "help", "helps", "allow",
        "allows", "every", "one", "two", "also", "just", "only", "own",
        "world", "life", "day", "daily", "small", "great", "fast", "quick",
        "quickly", "better", "well", "right", "now", "here", "there",
    ]

    /// 中英对照的软件用途概念。trigger 是「描述里出现什么才算」，
    /// terms 是「这个概念可以被哪些词搜到」。terms 里的词不必都出现在描述里。
    private static let concepts: [QuickSearchKeywordConcept] = [
        QuickSearchKeywordConcept(
            triggers: ["ai", "artificial intelligence", "人工智能", "大模型", "llm",
                       "gpt", "chatbot", "聊天机器人", "copilot", "machine learning", "机器学习"],
            terms: ["AI", "人工智能", "artificial intelligence", "智能", "大模型", "LLM",
                    "GPT", "chatbot", "聊天机器人", "copilot", "AI助手", "机器学习",
                    "machine learning", "文生图", "image generation", "Midjourney", "Stable Diffusion"]
        ),
        QuickSearchKeywordConcept(
            // agent 单独出现太像网络代理（user agent / proxy agent），
            // 只有「AI Agent」「智能体」「助手」这类组合才当作 AI 代理。
            triggers: ["ai agent", "aiagent", "智能体", "assistant", "助手", "copilot"],
            terms: ["Agent", "agent", "AI Agent", "智能体", "助手", "assistant", "代理"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["download", "downloader", "torrent", "bt", "magnet", "ed2k",
                       "下载", "下载器", "种子", "磁力"],
            terms: ["下载", "download", "downloader", "下载器", "torrent", "种子",
                    "BT", "magnet", "磁力", "ed2k"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["clean", "cleaner", "cleanup", "junk", "uninstall", "uninstaller",
                       "optimize", "optimizer", "清理", "垃圾", "卸载", "卸载器", "优化"],
            terms: ["清理", "clean", "cleaner", "cleanup", "junk", "垃圾", "卸载",
                    "uninstall", "uninstaller", "卸载器", "remove", "removal", "优化",
                    "optimize", "optimizer", "加速", "提速"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["disk", "storage", "volume", "磁盘", "硬盘", "空间", "容量"],
            terms: ["磁盘", "硬盘", "空间", "disk", "drive", "storage", "volume", "容量"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["awake", "caffeine", "keep awake", "prevent sleep", "防休眠",
                       "保持唤醒", "屏幕常亮", "防睡眠"],
            terms: ["保持唤醒", "防休眠", "休眠", "唤醒", "屏幕常亮", "awake", "caffeine",
                    "keep awake", "prevent sleep", "sleep"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["screenshot", "screen capture", "screen recording", "capture",
                       "recorder", "截图", "截屏", "录屏", "屏幕录制"],
            terms: ["截图", "截屏", "录屏", "屏幕录制", "screenshot", "screen capture",
                    "screen recording", "capture", "recorder", "OCR", "文字识别"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["photo", "image", "picture", "graphic", "图片", "照片", "图像", "看图", "修图"],
            terms: ["图片", "照片", "图像", "photo", "image", "picture", "viewer", "看图", "修图"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["video", "movie", "film", "clips", "视频", "影片", "剪辑", "转码"],
            terms: ["视频", "影片", "video", "movie", "player", "播放器", "剪辑", "transcode",
                    "converter", "转码"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["audio", "music", "sound", "podcast", "音频", "音乐", "播客"],
            terms: ["音频", "音乐", "audio", "music", "sound", "podcast", "播客",
                    "player", "播放器"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["browser", "web browser", "网页浏览", "浏览器"],
            terms: ["浏览器", "browser", "web", "网页", "网页浏览"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["chat", "message", "messaging", "social", "im", "聊天", "社交", "即时通讯"],
            terms: ["聊天", "社交", "chat", "message", "messaging", "social", "IM", "即时通讯"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["email", "e-mail", "mail", "inbox", "邮件", "邮箱"],
            terms: ["邮件", "邮箱", "email", "mail", "inbox"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["office", "document", "word", "excel", "powerpoint", "spreadsheet",
                       "presentation", "pdf", "办公", "文档", "表格", "演示"],
            terms: ["办公", "office", "文档", "document", "word", "excel", "powerpoint",
                    "spreadsheet", "表格", "presentation", "演示", "PDF"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["notes", "note taking", "notebook", "memo", "markdown", "writing",
                       "笔记", "记事", "备忘录", "写作"],
            terms: ["笔记", "notes", "note", "记事", "备忘录", "memo", "notebook",
                    "markdown", "写作", "writing"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["todo", "to-do", "task", "gtd", "project management", "reminder",
                       "待办", "任务", "项目管理", "提醒"],
            terms: ["待办", "任务", "todo", "task", "GTD", "project", "项目管理",
                    "reminder", "提醒"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["calendar", "schedule", "日历", "日程"],
            terms: ["日历", "calendar", "schedule", "日程"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["code", "coding", "developer", "programming", "ide", "compiler",
                       "debugger", "git", "开发", "编程", "代码"],
            terms: ["开发", "编程", "代码", "code", "coding", "developer", "programming",
                    "IDE", "compiler", "debugger", "Git"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["terminal", "shell", "command line", "terminal emulator",
                       "终端", "命令行"],
            terms: ["终端", "terminal", "shell", "命令行", "command line"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["database", "sql", "mysql", "postgres", "postgresql", "redis",
                       "mongodb", "sqlite", "数据库"],
            terms: ["数据库", "database", "SQL", "MySQL", "PostgreSQL", "Redis", "MongoDB", "SQLite"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["archive", "archiver", "zip", "unzip", "rar", "7z", "压缩", "解压", "压缩包"],
            terms: ["压缩", "解压", "archive", "archiver", "zip", "unzip", "rar", "7z", "压缩包"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["network", "proxy", "vpn", "dns", "packet", "firewall", "网络",
                       "代理", "加速器", "抓包", "防火墙"],
            terms: ["网络", "network", "proxy", "代理", "VPN", "加速器", "DNS",
                    "抓包", "packet", "firewall", "防火墙"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["remote", "ssh", "vnc", "rdp", "screen sharing", "远程", "投屏"],
            terms: ["远程", "remote", "SSH", "VNC", "RDP", "远程桌面", "远程控制",
                    "screen sharing", "投屏"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["security", "antivirus", "password", "keychain", "privacy",
                       "安全", "杀毒", "病毒", "密码", "隐私"],
            terms: ["安全", "security", "antivirus", "杀毒", "病毒", "password", "密码",
                    "keychain", "隐私", "privacy"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["finance", "accounting", "invoice", "budget", "stock",
                       "财务", "记账", "账单", "发票", "预算", "股票"],
            terms: ["财务", "finance", "记账", "账单", "invoice", "发票", "accounting",
                    "budget", "预算", "股票", "stock"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["design", "drawing", "sketch", "graphic design", "vector", "cad", "3d",
                       "设计", "作图", "绘图", "矢量", "建模"],
            terms: ["设计", "design", "作图", "绘图", "drawing", "sketch", "graphic",
                    "矢量", "vector", "CAD", "3D", "建模"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["translate", "translation", "dictionary", "翻译", "词典"],
            terms: ["翻译", "translate", "translation", "词典", "dictionary"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["meeting", "conference", "webinar", "video call", "会议", "视频会议", "通话"],
            terms: ["会议", "meeting", "视频会议", "conference", "webinar", "通话", "call"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["cloud", "sync", "backup", "restore", "网盘", "云盘", "同步", "备份", "恢复"],
            terms: ["网盘", "云盘", "云存储", "cloud", "drive", "sync", "同步",
                    "备份", "backup", "restore", "恢复"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["virtual machine", "vm", "docker", "container", "emulator",
                       "虚拟机", "容器", "模拟器"],
            terms: ["虚拟机", "virtual machine", "VM", "Docker", "container", "容器",
                    "模拟器", "emulator"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["automation", "workflow", "script", "macro", "shortcut",
                       "自动化", "工作流", "脚本", "宏", "快捷指令"],
            terms: ["自动化", "automation", "workflow", "工作流", "script", "脚本",
                    "macro", "宏", "shortcut", "快捷指令"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["reader", "reading", "ebook", "epub", "kindle", "阅读", "电子书"],
            terms: ["阅读", "read", "reader", "阅读器", "电子书", "ebook", "EPUB"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["game", "gaming", "游戏"],
            terms: ["游戏", "game", "gaming"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["map", "navigation", "gps", "地图", "导航"],
            terms: ["地图", "map", "导航", "navigation", "GPS", "路线"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["travel", "trip", "flight", "hotel", "旅行", "行程", "机票", "酒店"],
            terms: ["旅行", "travel", "trip", "行程", "机票", "flight", "酒店", "hotel"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["shopping", "shop", "ecommerce", "购物", "商城", "电商"],
            terms: ["购物", "shopping", "shop", "商城", "电商"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["study", "education", "course", "school", "学习", "教育", "课程"],
            terms: ["学习", "study", "教育", "education", "课程", "course", "school"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["health", "fitness", "workout", "running", "健康", "健身", "运动", "跑步"],
            terms: ["健康", "health", "健身", "fitness", "workout", "运动", "跑步"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["news", "rss", "feed", "新闻", "资讯"],
            terms: ["新闻", "资讯", "news", "RSS", "feed"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["food", "recipe", "restaurant", "美食", "菜谱", "餐饮"],
            terms: ["美食", "餐饮", "food", "recipe", "菜谱", "restaurant"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["sports", "scores", "体育", "比分"],
            terms: ["体育", "运动", "sports", "score", "比分"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["kids", "children", "亲子", "儿童"],
            terms: ["儿童", "kids", "children", "亲子"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["medical", "medicine", "病历", "医疗"],
            terms: ["医疗", "medical", "medicine", "健康", "病历"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["business", "erp", "crm", "customer", "sales", "企业", "商务", "客户", "销售"],
            terms: ["企业", "商务", "business", "ERP", "CRM", "客户", "customer",
                    "销售", "sales"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["weather", "forecast", "天气", "预报"],
            terms: ["天气", "weather", "forecast", "预报"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["mind map", "mindmap", "flowchart", "diagram", "思维导图", "流程图", "图表"],
            terms: ["思维导图", "mind map", "mindmap", "流程图", "flowchart", "diagram", "图表"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["clipboard", "paste", "剪贴板", "复制粘贴"],
            terms: ["剪贴板", "clipboard", "paste", "复制粘贴", "history"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["menu bar", "menubar", "status bar", "菜单栏", "状态栏"],
            terms: ["菜单栏", "menu bar", "menubar", "状态栏", "status bar"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["input method", "keyboard", "typing", "输入法", "键盘", "打字"],
            terms: ["输入法", "input method", "keyboard", "键盘", "打字", "typing"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["file manager", "file browser", "finder", "文件管理", "文件浏览"],
            terms: ["文件管理", "file manager", "file browser", "资源管理器", "文件浏览"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["streaming", "live stream", "obs", "直播", "推流"],
            terms: ["直播", "streaming", "live", "推流", "OBS"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["driver", "hardware", "printer", "驱动", "硬件", "打印机"],
            terms: ["驱动", "driver", "硬件", "hardware", "打印机", "printer"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["text editor", "code editor", "editor", "编辑器", "文本编辑"],
            terms: ["编辑器", "editor", "文本", "text", "写作", "writing"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["player", "播放器"],
            terms: ["播放器", "player", "媒体", "media"]
        ),
        QuickSearchKeywordConcept(
            triggers: ["window manager", "tiling", "snap windows", "窗口管理", "分屏"],
            terms: ["窗口管理", "window manager", "tiling", "snap", "分屏"]
        ),
    ]

    /// 从厂商写的描述、菜单名、package.json 关键词里取可搜索词。
    ///
    /// - Parameters:
    ///   - texts: 描述来源，每个元素单独参与概念命中计数。
    ///   - minimumConceptHits: 概念至少在几个来源里出现才算。描述默认 1；
    ///     UI 字符串兜底不走这里，见 `dominantKeywords`。
    ///   - includeRawTokens: 是否收录描述里有意义的原始词。UI 字符串兜底时关掉，
    ///     那里只接受词表能确认的概念。
    static func keywords(
        from texts: [String],
        minimumConceptHits: Int = 1,
        includeRawTokens: Bool = true,
        limit: Int = maximumKeywordTerms
    ) -> [String] {
        let prepared = preparedTexts(texts)
        guard !prepared.isEmpty else { return [] }

        var collected: [String] = []
        var seen = Set<String>()

        func append(_ candidates: [String]) {
            for candidate in candidates {
                let folded = compact(candidate)
                guard !folded.isEmpty, seen.insert(folded).inserted else { continue }
                collected.append(candidate)
                if collected.count >= limit { return }
            }
        }

        for concept in preparedConcepts {
            let hits = prepared.reduce(0) { count, text in
                count + (matches(concept, in: text) ? 1 : 0)
            }
            guard hits >= max(1, minimumConceptHits) else { continue }
            append(concept.terms)
            if collected.count >= limit { return Array(collected.prefix(limit)) }
        }

        if includeRawTokens {
            for text in prepared {
                append(rawTokens(in: text.tokens))
                if collected.count >= limit { break }
            }
        }
        return Array(collected.prefix(limit))
    }

    /// UI 文案兜底专用：一个应用的界面里到处是 image、clean、video 这类泛词，
    /// 「出现过两次」不足以说明用途。这里按**命中的文案条数**给概念排序，
    /// 只留最强的两个，第二个还必须达到第一名的一半证据量。
    /// DaisyDisk 的界面里 image / download 都会出现，但「磁盘」才是压倒性的那个。
    static func dominantKeywords(
        from texts: [String],
        minimumHits: Int,
        maximumConcepts: Int = 2,
        termsPerConcept: Int = 8
    ) -> [String] {
        let prepared = preparedTexts(texts)
        guard !prepared.isEmpty else { return [] }

        var scored: [(index: Int, terms: [String], hits: Int)] = []
        for (index, concept) in preparedConcepts.enumerated() {
            let hits = prepared.reduce(0) { count, text in
                count + (matches(concept, in: text) ? 1 : 0)
            }
            guard hits >= max(1, minimumHits) else { continue }
            scored.append((index, concept.terms, hits))
        }
        scored.sort { lhs, rhs in
            lhs.hits != rhs.hits ? lhs.hits > rhs.hits : lhs.index < rhs.index
        }
        guard let top = scored.first else { return [] }

        var result: [String] = []
        var seen = Set<String>()
        for (rank, entry) in scored.prefix(max(1, maximumConcepts)).enumerated() {
            // 第二名起要有一半的证据量，否则就是个顺带出现的词。
            if rank > 0, entry.hits * 2 < top.hits { break }
            for term in entry.terms.prefix(termsPerConcept) {
                let folded = compact(term)
                guard !folded.isEmpty, seen.insert(folded).inserted else { continue }
                result.append(term)
            }
        }
        return result
    }

    /// 已经由别处算好的概念词（例如 UI 字符串兜底），和描述词一起去重。
    static func merging(_ existing: [String], with additions: [String], limit: Int = maximumKeywordTerms) -> [String] {
        var collected: [String] = []
        var seen = Set<String>()
        for candidate in existing + additions {
            let folded = compact(candidate)
            guard !folded.isEmpty, seen.insert(folded).inserted else { continue }
            collected.append(candidate)
            if collected.count >= limit { break }
        }
        return collected
    }

    // MARK: - 匹配

    private struct PreparedText {
        let tokens: [String]
        let compact: String
    }

    private struct PreparedTrigger {
        /// 单个拉丁词走 token 比对；多词 trigger（"ai agent"）为 nil，走整段包含。
        let token: String?
        let phrase: String
    }

    private struct PreparedConcept {
        let terms: [String]
        let triggers: [PreparedTrigger]
    }

    /// trigger 的折叠/分词只做一次。UI 兜底是 55 个概念 × 最多 300 条文案，
    /// 若在每个 (概念, 文案) 组合里重新折叠 trigger，会白烧几十万次 ICU 调用。
    private static let preparedConcepts: [PreparedConcept] = concepts.map { concept in
        PreparedConcept(
            terms: concept.terms,
            triggers: concept.triggers.compactMap { trigger in
                let folded = compact(trigger)
                guard !folded.isEmpty else { return nil }
                var token: String?
                if isLatinWord(folded), !trigger.contains(" ") {
                    let triggerTokens = tokens(folded: folded)
                    if triggerTokens.count == 1 { token = triggerTokens[0] }
                }
                return PreparedTrigger(token: token, phrase: folded)
            }
        )
    }

    /// 分词与折叠只做一次。UI 兜底会拿两百条文案去比几十个概念，
    /// 逐概念重新分词会把这个后台步骤拖成秒级。
    private static func preparedTexts(_ texts: [String]) -> [PreparedText] {
        texts.compactMap { text in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let folded = QuickSearchTextNormalizer.fold(trimmed)
            return PreparedText(tokens: tokens(folded: folded), compact: compact(folded: folded))
        }
    }

    private static func matches(_ concept: PreparedConcept, in text: PreparedText) -> Bool {
        guard !text.compact.isEmpty else { return false }
        return concept.triggers.contains { trigger in
            if let needle = trigger.token {
                return text.tokens.contains { token in
                    if token == needle { return true }
                    return needle.count >= 3 && token.hasPrefix(needle)
                }
            }
            return text.compact.contains(trigger.phrase)
        }
    }

    // MARK: - 分词

    private static func tokens(folded: String) -> [String] {
        var result: [String] = []
        var latin = ""
        var han = ""

        func flushLatin() {
            if !latin.isEmpty {
                if latin.contains(where: { $0.isLetter }) { result.append(latin) }
                latin = ""
            }
        }
        func flushHan() {
            if !han.isEmpty { result.append(han); han = "" }
        }

        for scalar in folded.unicodeScalars {
            if QuickSearchTextNormalizer.hanCharacters.contains(scalar) {
                flushLatin()
                han.unicodeScalars.append(scalar)
            } else if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                flushHan()
                latin.unicodeScalars.append(scalar)
            } else {
                flushLatin()
                flushHan()
            }
        }
        flushLatin()
        flushHan()
        return result
    }

    private static func rawTokens(in tokens: [String]) -> [String] {
        tokens.filter { token in
            if isHanToken(token) {
                return token.count >= 2 && token.count <= 12
            }
            return token.count >= 3
                && token.contains(where: \.isLetter)
                && !stopwords.contains(token)
        }
    }

    private static func isLatinWord(_ string: String) -> Bool {
        !string.isEmpty && string.unicodeScalars.allSatisfy { $0.isASCII }
    }

    private static func isHanToken(_ token: String) -> Bool {
        token.unicodeScalars.contains { QuickSearchTextNormalizer.hanCharacters.contains($0) }
    }

    private static func compact(_ string: String) -> String {
        compact(folded: QuickSearchTextNormalizer.fold(string))
    }

    private static func compact(folded: String) -> String {
        String(folded.filter { character in
            character.isLetter || character.isNumber
        })
    }
}
