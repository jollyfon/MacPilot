//
//  DockHelperStrings.swift
//  MacPilotDockGroupsCore
//
//  Helper 是独立进程，不能依赖主程序的 AppText，
//  因此这里维护 Helper 自己需要的一小份中英文文案（需求第 24 节：Helper 职责只有这些）。
//

import Foundation

public enum DockHelperLanguage {
    case english
    case simplifiedChinese

    public static var system: DockHelperLanguage {
        Locale.autoupdatingCurrent.language.languageCode?.identifier == "zh" ? .simplifiedChinese : .english
    }
}

public enum DockHelperStrings {
    public static func value(_ key: String, language: DockHelperLanguage = .system) -> String {
        let table = language == .simplifiedChinese ? chinese : english
        return table[key] ?? english[key] ?? key
    }

    private static let chinese: [String: String] = [
        "settings": "设置…",
        "addApps": "添加应用…",
        "chooseApps": "选择要添加的应用",
        "add": "添加",
        "alreadyInGroup": "「%@」已在分组中",
        "saveFailed": "无法保存分组：%@",
        "emptyGroup": "这个分组还没有应用",
        "emptyGroupHint": "点标题旁的 + 选择应用，或打开 MacPilot → Dock 分组添加。",
        "appMissing": "应用未找到",
        "relocate": "重新定位",
        "removeFromGroup": "从分组移除",
        "groupMissing": "找不到该分组的配置",
        "groupMissingHint": "请在 MacPilot 的 Dock 分组页面重新生成这个分组。",
        "openMacPilot": "打开 MacPilot",
        "quit": "退出",
        "running": "正在运行",
        "notRunning": "未运行",
        "launchFailed": "无法打开「%@」",
        "showInFinder": "在访达中显示"
    ]

    private static let english: [String: String] = [
        "settings": "Settings…",
        "addApps": "Add Apps…",
        "chooseApps": "Choose apps to add",
        "add": "Add",
        "alreadyInGroup": "“%@” is already in this group",
        "saveFailed": "Could not save the group: %@",
        "emptyGroup": "No apps in this group yet",
        "emptyGroupHint": "Click + next to the title, or open MacPilot → Dock Groups.",
        "appMissing": "App not found",
        "relocate": "Locate…",
        "removeFromGroup": "Remove from group",
        "groupMissing": "This group's configuration is missing",
        "groupMissingHint": "Regenerate the group in MacPilot's Dock Groups page.",
        "openMacPilot": "Open MacPilot",
        "quit": "Quit",
        "running": "Running",
        "notRunning": "Not running",
        "launchFailed": "Could not open “%@”",
        "showInFinder": "Reveal in Finder"
    ]
}
