//
//  QuickSearchSettings.swift
//  MacPilot
//
//  快速搜索的设置（并入 config.json 的 `quickSearch` 一节）。
//

import Carbon.HIToolbox
import Foundation

/// 文件搜索的范围。
enum QuickSearchFileScope: String, Codable, Equatable, CaseIterable, Identifiable, Sendable {
    /// 当前用户的主目录。
    case home
    /// 整台 Mac 上 Spotlight 已索引的本地范围。
    case entireMac
    /// 用户自己指定的、且已被 Spotlight 索引的目录。
    case indexedDirectories

    var id: String { rawValue }
    var titleKey: String {
        switch self {
        case .home: "quickSearchScopeHome"
        case .entireMac: "quickSearchScopeEntireMac"
        case .indexedDirectories: "quickSearchScopeCustom"
        }
    }
}

/// 展示与内存上界的集中定义，不放进设置：这些不是用户选项，是实现约束。
enum QuickSearchLimits {
    /// 面板里最多展示的结果行数。
    static let visibleResults = 40
    /// 应用结果最多占用的行数，给文件结果留出空间。
    static let applicationResults = 20
    /// Spotlight 单次查询最多取回的条目数（内存上界，与展示量分开）。
    static let spotlightResults = 120
    /// 空查询时展示的最近应用条数。
    static let recentApplications = 8
    /// 收藏总条数上限。
    static let favorites = 24
    /// 空查询那一屏里收藏最多占的行数，剩下的留给最近使用。
    static let favoritesOnEmptyQuery = 12
    /// 自定义搜索目录数量上限。
    static let customDirectories = 12
    /// 输入防抖：连续打字时只在停手后发起一次 Spotlight 查询。
    static let debounceMilliseconds = 150
    /// 短查询（1 个字符）会产生海量命中，直接不查。
    static let minimumFileQueryCharacters = 2
}

/// 匹配范围：只认名字，还是名字之外也认应用自己声明的用途标签。
///
/// 默认带上用途：输入「图片」「下载」能捞到名字里没这两个词的软件，
/// 而名称命中的排序完全不受影响（标签命中排在所有名称命中之后）。
/// 不想要这层的人可以只留名称。
enum QuickSearchMatchScope: String, Codable, Equatable, CaseIterable, Identifiable, Sendable {
    case nameOnly
    case nameAndPurpose

    var id: String { rawValue }
    var titleKey: String {
        switch self {
        case .nameOnly: "quickSearchMatchNameOnly"
        case .nameAndPurpose: "quickSearchMatchNameAndPurpose"
        }
    }
}

struct QuickSearchSettings: Codable, Equatable, Sendable {
    /// 功能总开关。首页是唯一入口，这里只是运行时镜像（见 AGENTS.md）。
    var isEnabled: Bool
    /// 全局快捷键，默认 Option + Space。
    var hotkey: SmartCaptureShortcutBinding
    /// 文件搜索范围。
    var fileScope: QuickSearchFileScope
    /// `fileScope == .indexedDirectories` 时使用的目录绝对路径。
    var customDirectoryPaths: [String]
    /// 面板左上角的屏幕坐标；没拖动过时为 nil，沿用默认落点。
    var panelPosition: QuickSearchPanelPosition?
    /// 用户钉住的收藏，空查询时排在最前。
    var favorites: [QuickSearchFavorite]
    /// 只匹配名称，还是也匹配用途标签。
    var matchScope: QuickSearchMatchScope

    static let defaultHotkey = SmartCaptureShortcutBinding(
        keyCode: UInt16(kVK_Space),
        modifiers: [.option]
    )

    init(
        isEnabled: Bool = false,
        hotkey: SmartCaptureShortcutBinding = QuickSearchSettings.defaultHotkey,
        fileScope: QuickSearchFileScope = .home,
        customDirectoryPaths: [String] = [],
        panelPosition: QuickSearchPanelPosition? = nil,
        favorites: [QuickSearchFavorite] = [],
        matchScope: QuickSearchMatchScope = .nameAndPurpose
    ) {
        self.isEnabled = isEnabled
        self.hotkey = hotkey
        self.fileScope = fileScope
        self.customDirectoryPaths = Array(Set(customDirectoryPaths.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        })).sorted()
        self.panelPosition = panelPosition
        self.favorites = favorites
        self.matchScope = matchScope
    }

    var customDirectoryURLs: [URL] {
        customDirectoryPaths.map { URL(fileURLWithPath: $0) }
    }

    /// 名称之外还认不认用途标签。
    var matchesPurposeTags: Bool { matchScope == .nameAndPurpose }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, hotkey, fileScope, customDirectoryPaths, panelPosition, favorites, matchScope
    }

    /// 逐键 `decodeIfPresent`：以后新增字段时旧配置仍可加载（AGENTS.md 不变量）。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        // 存下来的快捷键原样保留，即使它按当前规则已不合法：注册侧会拒绝并说明原因，
        // 而不是悄悄把用户的配置改掉。
        hotkey = try container.decodeIfPresent(SmartCaptureShortcutBinding.self, forKey: .hotkey)
            ?? Self.defaultHotkey
        fileScope = try container.decodeIfPresent(QuickSearchFileScope.self, forKey: .fileScope) ?? .home
        customDirectoryPaths = try container.decodeIfPresent([String].self, forKey: .customDirectoryPaths) ?? []
        // 与剪贴板同一做法：坐标只在写入那一步把关（`rememberPanelPosition`），
        // 落盘的必然是有限值，读侧逐键补齐即可。
        panelPosition = try container.decodeIfPresent(QuickSearchPanelPosition.self, forKey: .panelPosition)
        favorites = try container.decodeIfPresent([QuickSearchFavorite].self, forKey: .favorites) ?? []
        // 认不出来的档位（比如用户装过更新的一版再降回来）只影响这一个选择，
        // 不能把收藏、面板位置、快捷键一起带走——那些是 `decodeIfPresent` 存在的理由。
        // 键不存在与值不认识都落到 `else`：`try?` 把抛错折成 nil，
        // `decodeIfPresent` 本身已经把「没有这个键」变成 nil。
        if let stored = try? container.decodeIfPresent(QuickSearchMatchScope.self, forKey: .matchScope) {
            matchScope = stored
        } else {
            matchScope = .nameAndPurpose
        }
    }
}
