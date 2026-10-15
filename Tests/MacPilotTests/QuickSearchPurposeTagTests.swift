//
//  QuickSearchPurposeTagTests.swift
//  MacPilot
//
//  应用「用途」标签：从 Info.plist 的声明里推出标签、标签参与匹配的边界、
//  名称的两个叫法都进索引、以及匹配范围这个新设置项的读写。
//
//  全部是纯函数与临时目录里的假 bundle——不扫用户的 /Applications，
//  不联网，不打开窗口。
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
    tags: [String] = []
) -> QuickSearchApplicationEntry {
    QuickSearchApplicationEntry(
        url: URL(fileURLWithPath: path),
        name: name,
        bundleIdentifier: bundleID,
        alternateNames: alternateNames,
        tags: tags
    )
}

private func searched(
    _ query: String,
    among entries: [QuickSearchApplicationEntry],
    includeTags: Bool
) -> [QuickSearchResult] {
    ApplicationSearchProvider.search(
        query: query,
        entries: entries,
        includeTags: includeTags,
        limit: 20
    )
}

// MARK: - 标签推导

struct QuickSearchPurposeTagTests {
    @Test func downloadersAreTaggedByTheSchemesTheyHandle() {
        let tags = QuickSearchAppTagger.tags(
            for: QuickSearchAppMetadata(urlSchemes: ["magnet", "ed2k", "thunder"])
        )

        #expect(tags.contains("下载"))
        #expect(tags.contains("download"))
    }

    @Test func browsersAreTaggedByHandlingHTTP() {
        let tags = QuickSearchAppTagger.tags(for: QuickSearchAppMetadata(urlSchemes: ["http", "https"]))

        #expect(tags.contains("浏览器"))
    }

    @Test func declaredDocumentTypesGivePurpose() {
        let tags = QuickSearchAppTagger.tags(
            for: QuickSearchAppMetadata(contentTypes: ["public.jpeg", "com.adobe.pdf"])
        )

        #expect(tags.contains("图片"))
        #expect(tags.contains("pdf"))
    }

    @Test func aBrowserDoesNotGetTaggedAsWhateverItCanOpen() {
        // Chrome 声明能打开 jpeg/pdf/mp4，只说明它什么都能打开。
        // 它的答案在「浏览器」那一档，不在「图片」那一档——否则输「图片」会先出来一排浏览器。
        let browser = QuickSearchAppTagger.tags(for: QuickSearchAppMetadata(
            categoryType: "public.app-category.productivity",
            urlSchemes: ["https", "http"],
            contentTypes: ["public.jpeg", "com.adobe.pdf", "public.mpeg-4"]
        ))

        #expect(browser.contains("浏览器"))
        #expect(!browser.contains("图片"))
        #expect(!browser.contains("pdf"))

        // 同样的声明，没有 http/https 的看图器就正常拿到标签。
        let viewer = QuickSearchAppTagger.tags(
            for: QuickSearchAppMetadata(contentTypes: ["public.jpeg", "com.adobe.pdf"])
        )
        #expect(viewer.contains("图片"))
        #expect(viewer.contains("pdf"))
    }

    @Test func categoryGivesPurposeOnlyWhenTheCategorySaysSomething() {
        #expect(QuickSearchAppTagger.tags(
            for: QuickSearchAppMetadata(categoryType: "public.app-category.photography")
        ).contains("图片"))

        // utilities、productivity 被厂商当「其余一切」用（本机各占 38 与 27 个），
        // developer-tools 是打包工具链的默认值（本机 52 个应用声称属于它，其中有
        // 有道云笔记、字由、QQ、天翼云盘）——三个都不给标签。
        #expect(QuickSearchAppTagger.tags(
            for: QuickSearchAppMetadata(categoryType: "public.app-category.utilities")
        ).isEmpty)
        #expect(QuickSearchAppTagger.tags(
            for: QuickSearchAppMetadata(categoryType: "public.app-category.productivity")
        ).isEmpty)
        #expect(QuickSearchAppTagger.tags(
            for: QuickSearchAppMetadata(categoryType: "public.app-category.developer-tools")
        ).isEmpty)

        // 真正的代码工具靠它声明的源码/脚本 UTI 认定，而不是靠分类。
        let ide = QuickSearchAppTagger.tags(for: QuickSearchAppMetadata(
            categoryType: "public.app-category.developer-tools",
            contentTypes: ["public.source-code", "com.apple.xcode.project", "public.plain-text"]
        ))
        #expect(ide.contains("开发"))
        #expect(ide.contains("代码"))

        // 只声明能打开纯文本的是文本编辑器，不是「开发工具」。
        let editor = QuickSearchAppTagger.tags(
            for: QuickSearchAppMetadata(contentTypes: ["public.plain-text", "public.json"])
        )
        #expect(editor.contains("文本"))
        #expect(!editor.contains("开发"))
    }

    @Test func boilerplateDeclarationsAreNotPurposes() {
        // 几乎每个应用都声明能打开文件夹与包，这不是用途。
        let tags = QuickSearchAppTagger.tags(
            for: QuickSearchAppMetadata(contentTypes: [
                "public.folder", "com.apple.package", "com.apple.application-bundle",
            ])
        )

        #expect(tags.isEmpty)
        #expect(QuickSearchAppTagger.tags(for: QuickSearchAppMetadata()).isEmpty)
        #expect(QuickSearchAppTagger.tags(
            for: QuickSearchAppMetadata(categoryType: "https://example.com/meta.json")
        ).isEmpty)
    }

    @Test func equivalentTagsFromDifferentSourcesAppearOnceAndAreCapped() {
        let tags = QuickSearchAppTagger.tags(for: QuickSearchAppMetadata(
            categoryType: "public.app-category.photography",
            urlSchemes: ["magnet"],
            contentTypes: ["public.image", "public.movie", "public.mp3", "com.adobe.pdf"]
        ))

        #expect(tags.filter { $0 == "图片" }.count == 1)
        #expect(tags.count <= QuickSearchAppTagger.maximumTagsPerApp)
        // 最强的行为证据排在最前：URL 方案 → 文档类型 → 分类。
        #expect(tags.first == "下载")
    }

    @Test func readsPurposeDeclarationsFromTheAppBundle() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("QuickSearchTags-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent("Fake.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>CFBundleName</key><string>Thunder</string>
          <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
          <key>CFBundleURLTypes</key><array><dict>
            <key>CFBundleURLSchemes</key><array><string>magnet</string><string>ed2k</string></array>
          </dict></array>
          <key>CFBundleDocumentTypes</key><array><dict>
            <key>LSItemContentTypes</key><array><string>public.movie</string></array>
          </dict></array>
        </dict></plist>
        """
        try plist.write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)

        let info = QuickSearchAppInfoReader.read(fromAppAt: app)

        #expect(info.metadata.categoryType == "public.app-category.utilities")
        #expect(info.metadata.urlSchemes == ["magnet", "ed2k"])
        #expect(info.metadata.contentTypes == ["public.movie"])
        #expect(info.alternateNames.contains("Thunder"))
        #expect(QuickSearchAppTagger.tags(for: info.metadata).contains("下载"))
        #expect(QuickSearchAppTagger.tags(for: info.metadata).contains("视频"))
    }

    @Test func anUnreadableBundleYieldsNoDeclarationsInsteadOfGuesses() {
        let info = QuickSearchAppInfoReader.read(
            fromAppAt: URL(fileURLWithPath: "/nonexistent/Fake.app", isDirectory: true)
        )

        #expect(info.metadata == QuickSearchAppMetadata())
        #expect(info.alternateNames.isEmpty)
    }
}

// MARK: - 标签参与匹配

struct QuickSearchPurposeMatchTests {
    private var downloader: QuickSearchApplicationEntry {
        makeEntry("Motrix", at: "/Applications/Motrix.app", bundleID: "com.test.motrix", tags: ["下载", "download"])
    }

    @Test func purposeWordsMatchOnlyWhenTheSettingAllowsThem() {
        let off = searched("下载", among: [downloader], includeTags: false)
        let on = searched("下载", among: [downloader], includeTags: true)

        #expect(off.isEmpty)
        #expect(on.map(\.title) == ["Motrix"])
        #expect(on.first?.matchedTagTerms == ["下载"])
    }

    @Test func nameMatchesNeverSayTheyMatchedByPurpose() {
        let results = searched("motrix", among: [downloader], includeTags: true)

        #expect(results.map(\.title) == ["Motrix"])
        #expect(results.first?.matchedTagTerms.isEmpty == true)
    }

    @Test func anAppNameAlwaysOutranksAnotherAppsPurpose() {
        let entries = [
            makeEntry("下载工具的副本", at: "/Applications/Name.app", bundleID: "com.test.name"),
            downloader,
        ]

        let results = searched("下载", among: entries, includeTags: true)

        #expect(results.map(\.title) == ["下载工具的副本", "Motrix"])
    }

    @Test func aWiderPhraseStillMatchesTheShorterTag() {
        let results = searched("下载器", among: [downloader], includeTags: true)

        #expect(results.map(\.title) == ["Motrix"])
    }

    @Test func shortLatinPrefixesDoNotSummonAWholeCategory() {
        // 「co」前缀能命中 code，等于把全部开发工具端上来；那是噪声。
        let editor = makeEntry("UltraEdit", at: "/Applications/UltraEdit.app", tags: ["代码", "code"])

        #expect(searched("co", among: [editor], includeTags: true).isEmpty)
        #expect(searched("cod", among: [editor], includeTags: true).count == 1)
        #expect(searched("code", among: [editor], includeTags: true).count == 1)
        // 中文标签只有 2 个字，2 个字符就该能用。
        #expect(searched("代码", among: [editor], includeTags: true).count == 1)
        #expect(searched("代", among: [editor], includeTags: true).isEmpty)
    }

    @Test func tagsAreNotReadAsPinyin() {
        // 输入 `xiazai` 不该因为标签「下载」而捞出下载器：那层的拼音只属于名称。
        #expect(searched("xiazai", among: [downloader], includeTags: true).isEmpty)
    }
}

// MARK: - 名称的两种叫法

struct QuickSearchNameVariantTests {
    @Test func aLocalizedNameIsSearchableByItsBundleNameToo() {
        // Finder 显示「迅雷」，包名与 Info.plist 里写的是 Thunder。
        // 只索引其中一个，另一个叫法就什么都搜不到。
        let entry = makeEntry(
            "迅雷",
            at: "/Applications/Thunder.app",
            bundleID: "com.test.thunder",
            alternateNames: ["Thunder", "迅雷", "Thunder"]
        )

        #expect(entry.fields.names.count == 2)
        #expect(entry.name == "迅雷")
        let results = searched("thunder", among: [entry], includeTags: false)
        #expect(results.map(\.title) == ["迅雷"])
    }

    @Test func everyNameVariantCarriesItsOwnPinyin() {
        let entry = makeEntry(
            "BaiduNetdisk",
            at: "/Applications/BaiduNetdisk_mac.app",
            alternateNames: ["百度网盘"]
        )

        // 中文名是别名，但它的拼音与首字母一样进了索引。
        #expect(searched("baiduwangpan", among: [entry], includeTags: false).count == 1)
        #expect(searched("bdwp", among: [entry], includeTags: false).count == 1)
        #expect(searched("baidu", among: [entry], includeTags: false).count == 1)
    }

    @Test func tagsRideAlongWithoutChangingWhatTheNameMatches() {
        let entry = makeEntry("Picview", at: "/Applications/Picview.app", tags: ["图片"])
        let fields = entry.fields

        #expect(fields.tags.map(\.folded) == ["图片"])
        #expect(entry.displayTags == ["图片"])
        #expect(searched("picview", among: [entry], includeTags: false).count == 1)
    }
}

// MARK: - 设置项

struct QuickSearchMatchScopeSettingsTests {
    private func decode(_ json: String) throws -> QuickSearchSettings {
        try JSONDecoder().decode(QuickSearchSettings.self, from: Data(json.utf8))
    }

    @Test func matchScopeDefaultsToIncludingPurposeAndRoundTrips() throws {
        var settings = QuickSearchSettings()
        #expect(settings.matchScope == .nameAndPurpose)
        #expect(settings.matchesPurposeTags)

        settings.matchScope = .nameOnly
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(QuickSearchSettings.self, from: data)

        #expect(decoded.matchScope == .nameOnly)
        #expect(!decoded.matchesPurposeTags)
    }

    @Test func olderConfigurationsWithoutTheKeyFallBackToTheDefault() throws {
        // 升级前写下的配置里没有 matchScope：不能要求这个键存在。
        let legacy = try decode(#"{"isEnabled":true,"fileScope":"home"}"#)
        #expect(legacy.matchScope == .nameAndPurpose)
        let empty = try decode("{}")
        #expect(empty.matchScope == .nameAndPurpose)
    }

    @Test func anUnrecognisedMatchScopeValueKeepsTheRestOfTheSection() throws {
        // 装过更新的一版再降回来时，配置文件里可能有本版本不认识的档位值。
        // 这只影响这一个选择，收藏与面板位置必须原样留下——清空整节就是
        // v1.1.482-beta.5 那次事故的形状。
        let settings = try decode(#"""
        {"matchScope":"telepathy","favorites":[{"identity":"bid:com.test.a","path":"/Applications/A.app","kind":"application","title":"A","subtitle":"/Applications"}]}
        """#)

        #expect(settings.matchScope == .nameAndPurpose)
        #expect(settings.favorites.count == 1)
    }
}
