//
//  QuickSearchDescriptionTests.swift
//  MacPilot
//
//  厂商写在应用包里的描述与关键词：中英互搜、层级低于名称、匹配范围开关，
//  以及 Electron package.json、InternetAccessPolicy、本地化名称与 UI 文案兜底。
//
//  全部是临时目录里的假 bundle，不读用户的应用，不联网。
//

import Foundation
import Testing

@testable import MacPilot

// MARK: - 测试数据

private func makeEntry(
    _ name: String,
    at path: String,
    bundleID: String? = nil,
    alternateNames: [String] = [],
    tags: [String] = [],
    descriptions: [String] = [],
    inferredKeywords: [String] = []
) -> QuickSearchApplicationEntry {
    QuickSearchApplicationEntry(
        url: URL(fileURLWithPath: path),
        name: name,
        bundleIdentifier: bundleID,
        alternateNames: alternateNames,
        tags: tags,
        descriptions: descriptions,
        inferredKeywords: inferredKeywords
    )
}

private func searched(
    _ query: String,
    among entries: [QuickSearchApplicationEntry],
    includeTags: Bool = true,
    usage: (QuickSearchApplicationEntry) -> Int = { _ in 0 }
) -> [QuickSearchResult] {
    ApplicationSearchProvider.search(
        query: query,
        entries: entries,
        usage: usage,
        includeTags: includeTags,
        limit: 20
    )
}

/// 建一个内容为空的假 `.app`，返回 app 路径；调用方负责删除它的父目录。
private func makeTemporaryApp(_ name: String = "Fake") throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("QuickSearchDescription-\(UUID().uuidString)", isDirectory: true)
    let app = root.appendingPathComponent("\(name).app", isDirectory: true)
    try FileManager.default.createDirectory(
        at: app.appendingPathComponent("Contents", isDirectory: true),
        withIntermediateDirectories: true
    )
    return app
}

private func writePlist(_ object: [String: Any], to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let data = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    try data.write(to: url)
}

// MARK: - 描述参与搜索

struct QuickSearchDescriptionMatchingTests {
    @Test func aVendorDescriptionIsSearchableInChineseAndEnglish() {
        // WorkBuddy 的 app.asar 里写着 “WorkBuddy Desktop - AI Agent Desktop Application”。
        let workBuddy = makeEntry(
            "WorkBuddy",
            at: "/Applications/WorkBuddy.app",
            descriptions: ["WorkBuddy Desktop - AI Agent Desktop Application"]
        )

        #expect(searched("智能体", among: [workBuddy]).map(\.title) == ["WorkBuddy"])
        #expect(searched("人工智能", among: [workBuddy]).map(\.title) == ["WorkBuddy"])
        #expect(searched("agent", among: [workBuddy]).map(\.title) == ["WorkBuddy"])
        #expect(searched("ai", among: [workBuddy]).map(\.title) == ["WorkBuddy"])
        let matched = searched("智能体", among: [workBuddy]).first?.matchedTagTerms ?? []
        #expect(matched.contains("智能体"), "matched=\(matched) keywords=\(workBuddy.fields.keywords.map(\.display))")
    }

    @Test func aChineseDescriptionIsSearchableInEnglish() {
        // 迅雷的 NSServices 菜单名与描述都是「下载」，英文输入也该找得到。
        let thunder = makeEntry(
            "迅雷",
            at: "/Applications/Thunder.app",
            alternateNames: ["Thunder"],
            descriptions: ["迅雷下载，支持磁力链接"]
        )

        #expect(searched("download", among: [thunder]).map(\.title) == ["迅雷"])
        #expect(searched("torrent", among: [thunder]).map(\.title) == ["迅雷"])
    }

    @Test func aNameHitOutranksEveryDescriptionHit() {
        let named = makeEntry("Downloader", at: "/Applications/Downloader.app", bundleID: "com.test.downloader")
        let described = makeEntry(
            "Motrix",
            at: "/Applications/Motrix.app",
            bundleID: "com.test.motrix",
            descriptions: ["Fast download manager"]
        )

        let results = searched("download", among: [described, named])

        #expect(results.map(\.title) == ["Downloader", "Motrix"])
        #expect(QuickSearchMatcher.match(
            query: "download",
            fields: described.fields,
            includeTags: true
        )?.tier == .keyword)
    }

    @Test func aFuzzyNameStillBeatsADescriptionHit() {
        let fuzzyName = makeEntry("Superlonghostname", at: "/Applications/a.app")
        let described = makeEntry(
            "Motrix",
            at: "/Applications/b.app",
            descriptions: ["Fast download manager"]
        )

        let ranked = searched("sln", among: [described, fuzzyName])
        #expect(ranked.map(\.title) == ["Superlonghostname"])
    }

    @Test func descriptionHitsFollowTheMatchScopeSetting() {
        let workBuddy = makeEntry(
            "WorkBuddy",
            at: "/Applications/WorkBuddy.app",
            descriptions: ["AI Agent Desktop Application"]
        )

        #expect(searched("智能体", among: [workBuddy], includeTags: false).isEmpty)
        #expect(searched("智能体", among: [workBuddy], includeTags: true).count == 1)
    }

    @Test func aChinesePhraseFromTheDescriptionMatchesWithoutALexiconEntry() {
        let whiteboard = makeEntry(
            "BoardX",
            at: "/Applications/BoardX.app",
            descriptions: ["团队协作白板，支持多人实时协作"]
        )

        #expect(searched("协作白板", among: [whiteboard]).map(\.title) == ["BoardX"])
    }

    @Test func latinDescriptionsDoNotMatchScatteredSubstrings() {
        // `ai` 不该在 email 里命中——拉丁输入不做描述原文的松散包含。
        let mail = makeEntry(
            "Postbox",
            at: "/Applications/Postbox.app",
            descriptions: ["A tidy email client"]
        )

        #expect(searched("ai", among: [mail]).isEmpty)
        #expect(searched("email", among: [mail]).map(\.title) == ["Postbox"])
    }

    @Test func shortLatinQueriesDoNotPullInADescriptionCategory() {
        let cleaner = makeEntry(
            "Sweeper",
            at: "/Applications/Sweeper.app",
            descriptions: ["Disk cleanup and uninstall utility"]
        )

        #expect(searched("cl", among: [cleaner]).isEmpty)
        #expect(searched("cle", among: [cleaner]).count == 1)
        #expect(searched("清理", among: [cleaner]).count == 1)
    }

    @Test func rawVendorKeywordsJoinTheDescriptionIndex() {
        let entry = makeEntry(
            "BoardX",
            at: "/Applications/BoardX.app",
            descriptions: ["团队协作白板"],
            inferredKeywords: ["whiteboard", "brainstorm"]
        )

        #expect(searched("whiteboard", among: [entry]).map(\.title) == ["BoardX"])
        #expect(searched("brainstorm", among: [entry]).map(\.title) == ["BoardX"])
        #expect(searched("white", among: [entry]).map(\.title) == ["BoardX"])
    }
}

// MARK: - 从应用包里读描述

struct QuickSearchVendorMetadataReadingTests {
    @Test func readsDescriptionAndProductNameFromAnAsarArchive() throws {
        let app = try makeTemporaryApp("WorkBuddy")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        let packageJSON = #"""
        {"name":"workbuddy","productName":"WorkBuddy","description":"WorkBuddy Desktop - AI Agent Desktop Application","keywords":["ai","agent"]}
        """#
        let package = Data(packageJSON.utf8)
        try makeAsar(package: package).write(to: resources.appendingPathComponent("app.asar"))

        let metadata = try #require(QuickSearchElectronMetadataReader.read(fromResourcesAt: resources))

        #expect(metadata.productName == "WorkBuddy")
        #expect(metadata.descriptions.count == 2)
        #expect(metadata.descriptions.first?.contains("AI Agent") == true)
        #expect(metadata.descriptions.last == "ai agent")

        // 整条链路：Info.plist 只有名字，描述来自 asar。
        try writePlist(["CFBundleName": "WorkBuddy"], to: app.appendingPathComponent("Contents/Info.plist"))
        let info = QuickSearchAppInfoReader.read(fromAppAt: app)
        #expect(info.alternateNames.contains("WorkBuddy"))
        #expect(info.descriptions.contains { $0.contains("AI Agent") })
    }

    @Test func readsTheInternetAccessPolicyDescription() throws {
        let app = try makeTemporaryApp("AppCleaner")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        try writePlist(
            ["CFBundleName": "AppCleaner"],
            to: app.appendingPathComponent("Contents/Info.plist")
        )
        try writePlist(
            ["ApplicationDescription": "Completely uninstall unwanted applications."],
            to: app.appendingPathComponent("Contents/Resources/InternetAccessPolicy.plist")
        )

        let info = QuickSearchAppInfoReader.read(fromAppAt: app)

        #expect(info.descriptions == ["Completely uninstall unwanted applications."])
        #expect(QuickSearchKeywordLexicon.keywords(from: info.descriptions).contains("卸载"))
    }

    @Test func localizedInfoPlistNamesBecomeAlternateNames() throws {
        let app = try makeTemporaryApp("Thunder")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        try writePlist(
            ["CFBundleName": "Thunder"],
            to: app.appendingPathComponent("Contents/Info.plist")
        )
        try writePlist(
            ["CFBundleDisplayName": "迅雷"],
            to: app.appendingPathComponent("Contents/Resources/zh_CN.lproj/InfoPlist.strings")
        )
        try writePlist(
            ["CFBundleDisplayName": "Thunder"],
            to: app.appendingPathComponent("Contents/Resources/en.lproj/InfoPlist.strings")
        )

        let info = QuickSearchAppInfoReader.read(fromAppAt: app)

        #expect(info.alternateNames.contains("迅雷"))
        #expect(info.alternateNames.contains("Thunder"))
        // 同一个名字不能因为来自 Info.plist 和本地化文件就进索引两次。
        #expect(info.alternateNames.filter { $0 == "Thunder" }.count == 1)
    }

    @Test func bundledServiceMenuTitlesCarryPurposeWords() throws {
        let app = try makeTemporaryApp("Thunder")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        try writePlist(
            [
                "CFBundleName": "Thunder",
                "NSServices": [
                    ["NSMenuItem": ["default": "迅雷下载"]],
                ],
            ],
            to: app.appendingPathComponent("Contents/Info.plist")
        )

        let info = QuickSearchAppInfoReader.read(fromAppAt: app)
        let entry = QuickSearchApplicationEntry(
            url: app,
            name: "迅雷",
            bundleIdentifier: nil,
            descriptions: info.descriptions
        )

        #expect(info.descriptions.contains("迅雷下载"))
        #expect(info.tags.isEmpty)
        #expect(searched("下载", among: [entry]).map(\.title) == ["迅雷"])
    }

    @Test func copyrightGetInfoStringsAreNotDescriptions() {
        let plist: [String: Any] = ["CFBundleGetInfoString": "Copyright © 2026 Example. All rights reserved."]

        #expect(QuickSearchVendorMetadataReader.descriptiveGetInfoString(from: plist) == nil)
        #expect(QuickSearchVendorMetadataReader.descriptiveGetInfoString(
            from: ["CFBundleGetInfoString": "Universal Database Manager and SQL client."]
        ) == "Universal Database Manager and SQL client.")
    }

    @Test func aBundleWithNoDeclarationFallsBackToConfirmedUiConceptsOnly() throws {
        let app = try makeTemporaryApp("Sweeper")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        try writePlist(
            ["CFBundleName": "Sweeper"],
            to: app.appendingPathComponent("Contents/Info.plist")
        )
        try writePlist(
            [
                "clean.title": "Clean up your Mac",
                "clean.action": "Uninstall apps completely",
                "clean.junk": "Remove junk files",
            ],
            to: app.appendingPathComponent("Contents/Resources/en.lproj/Localizable.strings")
        )

        let info = QuickSearchAppInfoReader.read(fromAppAt: app)

        #expect(info.tags.isEmpty)
        #expect(info.descriptions.isEmpty)
        #expect(info.inferredKeywords.contains("清理"))
        #expect(info.inferredKeywords.contains("卸载"))
    }

    @Test func theFallbackKeepsOnlyTheDominantConcept() {
        let texts = [
            "Disk full", "Free up disk space", "Disk usage", "Choose a disk",
            "Disk is full", "Open image", "Image preview",
        ]

        let keywords = QuickSearchKeywordLexicon.dominantKeywords(from: texts, minimumHits: 3)

        #expect(keywords.contains("磁盘"))
        // 「图片」只出现在两条文案里，不到磁盘证据量的一半，不算用途。
        #expect(!keywords.contains("图片"))
    }

    @Test func fewerThanThreeUiStringsAreNotEvidence() {
        let keywords = QuickSearchKeywordLexicon.dominantKeywords(
            from: ["Clean up", "Remove junk"],
            minimumHits: 3
        )

        #expect(keywords.isEmpty)
    }

    @Test func aSingleIncidentalUiWordDoesNotBecomeAPurpose() throws {
        let app = try makeTemporaryApp("Notes")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        try writePlist(
            ["CFBundleName": "Notes"],
            to: app.appendingPathComponent("Contents/Info.plist")
        )
        try writePlist(
            ["clean.button": "Clean"],
            to: app.appendingPathComponent("Contents/Resources/en.lproj/Localizable.strings")
        )

        let info = QuickSearchAppInfoReader.read(fromAppAt: app)

        #expect(info.inferredKeywords.isEmpty)
    }

    @Test func declaredTagsSkipTheUiStringsFallback() throws {
        let app = try makeTemporaryApp("Thunder")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        try writePlist(
            [
                "CFBundleName": "Thunder",
                "CFBundleURLTypes": [["CFBundleURLSchemes": ["magnet"]]],
            ],
            to: app.appendingPathComponent("Contents/Info.plist")
        )
        try writePlist(
            ["screenshot.title": "Take a screenshot", "screenshot.hint": "Capture the screen"],
            to: app.appendingPathComponent("Contents/Resources/en.lproj/Localizable.strings")
        )

        let info = QuickSearchAppInfoReader.read(fromAppAt: app)

        #expect(info.tags.contains("下载"))
        // 已有厂商声明时不再读 UI 文案，避免把顺带出现的词当成用途。
        #expect(info.inferredKeywords.isEmpty)
    }
}

// MARK: - asar 构造

/// 按 asar 的 pickle 头布局拼一个只有根级 package.json 的最小归档。
private func makeAsar(package: Data) -> Data {
    let headerJSON = Data(
        #"{"files":{"package.json":{"size":\#(package.count),"offset":"0"}}}"#.utf8
    )
    let paddedCount = (headerJSON.count + 3) / 4 * 4
    let headerSize = 8 + paddedCount

    var data = Data()
    data.append(contentsOf: uint32Bytes(4))
    data.append(contentsOf: uint32Bytes(UInt32(headerSize)))
    data.append(contentsOf: uint32Bytes(UInt32(headerJSON.count + 4)))
    data.append(contentsOf: uint32Bytes(UInt32(headerJSON.count)))
    data.append(headerJSON)
    data.append(Data(repeating: 0, count: paddedCount - headerJSON.count))
    data.append(package)
    return data
}

private func uint32Bytes(_ value: UInt32) -> [UInt8] {
    [
        UInt8(value & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 24) & 0xFF),
    ]
}
