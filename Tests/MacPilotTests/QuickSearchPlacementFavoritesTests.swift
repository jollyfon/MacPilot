//
//  QuickSearchPlacementFavoritesTests.swift
//  MacPilot
//
//  面板落点的纯计算，与收藏的纯规则。两边都不开窗、不碰磁盘：
//  位置算的是 NSRect，收藏算的是数组，全部可以在主 Actor 之外断言。
//

import AppKit
import Testing

@testable import MacPilot

// MARK: - 落点

struct QuickSearchPlacementTests {
    private static let screen = NSRect(x: 0, y: 0, width: 1_440, height: 900)

    @Test func noRememberedPositionLandsCentredInTheUpperHalf() {
        let frame = QuickSearchPanelLayout.positionedFrame(
            rowCount: 0, savedPosition: nil, visibleFrames: [Self.screen], preferredFrame: Self.screen
        )
        // 默认落点还是老行为：水平居中、在上半屏，且完整落在可见区内。
        #expect(abs(frame.midX - Self.screen.midX) < 0.01)
        #expect(frame.midY > Self.screen.midY)
        #expect(Self.screen.contains(frame))
    }

    @Test func rememberedPositionComesBackExactlyWhereItWasDropped() {
        let saved = QuickSearchPanelPosition(x: 300, y: 800)
        let frame = QuickSearchPanelLayout.positionedFrame(
            rowCount: 3, savedPosition: saved, visibleFrames: [Self.screen], preferredFrame: Self.screen
        )
        #expect(frame.minX == 300)
        // 存的是左上角，还原的也必须是左上角。
        #expect(frame.maxY == 800)
    }

    @Test func theTopEdgeStaysPinnedWhileTheResultCountChangesTheHeight() {
        let saved = QuickSearchPanelPosition(x: 300, y: 800)
        let empty = QuickSearchPanelLayout.positionedFrame(
            rowCount: 0, savedPosition: saved, visibleFrames: [Self.screen], preferredFrame: Self.screen
        )
        let full = QuickSearchPanelLayout.positionedFrame(
            rowCount: 20, savedPosition: saved, visibleFrames: [Self.screen], preferredFrame: Self.screen
        )
        // 结果变多只往下长：输入行不能因为高度变化被顶出屏幕。
        #expect(empty.maxY == 800)
        #expect(full.maxY == 800)
        #expect(full.height > empty.height)
    }

    @Test func aRememberedSpotOnAnotherDisplayStaysOnThatDisplay() {
        let main = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let second = NSRect(x: 1_440, y: 0, width: 2_400, height: 1_440)
        let frame = QuickSearchPanelLayout.positionedFrame(
            rowCount: 3,
            savedPosition: QuickSearchPanelPosition(x: 2_000, y: 1_400),
            visibleFrames: [main, second],
            // 指针此刻在主屏：记住的位置在第二块屏，回收边界得按重叠最多的那块算。
            preferredFrame: main
        )
        #expect(frame.minX == 2_000)
        #expect(frame.maxY == 1_400)
        #expect(second.contains(frame))
    }

    @Test func aRememberedSpotThatNoLongerExistsIsPulledBackOnScreen() {
        // 拔掉第二块屏之后坐标还在，但不能回到用户看不见的地方。
        let frame = QuickSearchPanelLayout.positionedFrame(
            rowCount: 3, savedPosition: QuickSearchPanelPosition(x: 5_000, y: 2_000),
            visibleFrames: [Self.screen], preferredFrame: Self.screen
        )
        #expect(Self.screen.contains(frame))
        #expect(frame.maxX == Self.screen.maxX)
        #expect(frame.maxY == Self.screen.maxY)
    }

    @Test func heightGrowsWithRowsButNeverBeyondTheVisibleScreen() {
        let tall = QuickSearchPanelLayout.size(rowCount: 20, visibleFrame: Self.screen)
        let short = QuickSearchPanelLayout.size(rowCount: 0, visibleFrame: Self.screen)
        #expect(tall.height > short.height)
        #expect(tall.height <= Self.screen.height - 80)

        let cramped = NSRect(x: 0, y: 0, width: 1_440, height: 400)
        #expect(QuickSearchPanelLayout.size(rowCount: 20, visibleFrame: cramped).height == 320)
    }

    @Test func widthShrinksOnANarrowScreenButNeverBelowTheMinimum() {
        let narrow = NSRect(x: 0, y: 0, width: 480, height: 900)
        let size = QuickSearchPanelLayout.size(rowCount: 4, visibleFrame: narrow)
        #expect(size.width == QuickSearchPanelLayout.minimumWidth)
        #expect(size.width <= narrow.width)
    }
}

// MARK: - 收藏规则

private func appFavorite(
    _ title: String,
    bundleID: String,
    path: String,
    addedAt seconds: TimeInterval
) -> QuickSearchFavorite {
    QuickSearchFavorite(
        identity: QuickSearchUsageStore.identity(bundleIdentifier: bundleID, path: path),
        path: path,
        kind: .application,
        title: title,
        subtitle: (path as NSString).deletingLastPathComponent,
        bundleIdentifier: bundleID,
        addedAt: Date(timeIntervalSince1970: seconds)
    )
}

struct QuickSearchFavoritesTests {
    @Test func favoritingAnAppKeysItByBundleIDSoMovingItKeepsThePin() {
        let result = QuickSearchResult(
            kind: .application, title: "Mail", subtitle: "/Applications",
            url: URL(fileURLWithPath: "/Applications/Mail.app"), bundleIdentifier: "com.apple.mail"
        )
        #expect(result.favoriteIdentity == "bid:com.apple.mail")
        #expect(QuickSearchFavorite(result: result).path == "/Applications/Mail.app")
    }

    @Test func favoritingAFileKeysItByPath() {
        let result = QuickSearchResult(
            kind: .file, title: "报告.pdf", subtitle: "/Users/me/Documents",
            url: URL(fileURLWithPath: "/Users/me/Documents/报告.pdf")
        )
        #expect(result.favoriteIdentity == "path:/Users/me/Documents/报告.pdf")
    }

    @Test func refavoritingKeepsTheOneRowAndItsOriginalPlace() {
        let a = appFavorite("A", bundleID: "com.test.a", path: "/Applications/A.app", addedAt: 10)
        let b = appFavorite("B", bundleID: "com.test.b", path: "/Applications/B.app", addedAt: 20)

        var list = QuickSearchFavorites.add(a, to: [], limit: 8)
        list = QuickSearchFavorites.add(b, to: list, limit: 8)
        list = QuickSearchFavorites.add(a, to: list, limit: 8)

        #expect(list.map(\.title) == ["A", "B"])
        // 重复收藏不是「挪到最后」，也不该改写首次钉住的时间。
        #expect(list.first?.addedAt == Date(timeIntervalSince1970: 10))
    }

    @Test func aFullFavoriteListDropsTheEarliestPin() {
        let a = appFavorite("A", bundleID: "com.test.a", path: "/Applications/A.app", addedAt: 10)
        let b = appFavorite("B", bundleID: "com.test.b", path: "/Applications/B.app", addedAt: 20)
        let c = appFavorite("C", bundleID: "com.test.c", path: "/Applications/C.app", addedAt: 30)

        let list = QuickSearchFavorites.add(c, to: [a, b], limit: 2)
        #expect(list.map(\.title) == ["B", "C"])
    }

    @Test func removingOneFavoriteLeavesTheOthersAlone() {
        let a = appFavorite("A", bundleID: "com.test.a", path: "/Applications/A.app", addedAt: 10)
        let b = appFavorite("B", bundleID: "com.test.b", path: "/Applications/B.app", addedAt: 20)

        #expect(QuickSearchFavorites.remove(identity: a.identity, from: [a, b]) == [b])
        #expect(QuickSearchFavorites.contains(identity: b.identity, in: [a, b]))
        #expect(!QuickSearchFavorites.contains(identity: "path:/Applications/C.app", in: [a, b]))
    }

    @Test func favoritesOrderThemselvesByOpensThenByPinningTime() {
        let a = appFavorite("A", bundleID: "com.test.a", path: "/Applications/A.app", addedAt: 30)
        let b = appFavorite("B", bundleID: "com.test.b", path: "/Applications/B.app", addedAt: 10)
        let c = appFavorite("C", bundleID: "com.test.c", path: "/Applications/C.app", addedAt: 20)
        let counts: [String: Int] = ["bid:com.test.a": 1, "bid:com.test.b": 5, "bid:com.test.c": 5]

        let ordered = QuickSearchFavorites.ordered([a, b, c]) { counts[$0.identity] ?? 0 }
        // 次数多的在前；同为 5 次时按先钉住的那个，与搜索结果同一把尺子。
        #expect(ordered.map(\.title) == ["B", "C", "A"])
    }

    @Test func theEmptyQueryScreenListsFavoritesFirstThenRecentsWithoutRepeats() {
        let safari = QuickSearchApplicationEntry(
            url: URL(fileURLWithPath: "/Applications/Safari.app"), name: "Safari", bundleIdentifier: "com.test.safari"
        )
        let notes = QuickSearchApplicationEntry(
            url: URL(fileURLWithPath: "/Applications/Notes.app"), name: "备忘录", bundleIdentifier: "com.test.notes"
        )
        let favorite = appFavorite("Safari", bundleID: "com.test.safari", path: "/Applications/Safari.app", addedAt: 5)
        let recents = [safari, notes].map { QuickSearchResult(application: $0) }

        let rows = QuickSearchFavorites.rows(
            favorites: [favorite], entries: [safari, notes], recent: recents,
            favoriteLimit: 12, totalLimit: 20
        )
        // Safari 只出现一次：收藏在前，最近使用补齐后面。
        #expect(rows.map(\.title) == ["Safari", "备忘录"])
    }

    @Test func favoritesStillShowWhileTheAppIndexIsBuilding() {
        // 索引还没落地时不能看着像「收藏空了」，所以退回记录里的快照。
        let favorite = appFavorite("计算器", bundleID: "com.test.calc", path: "/Applications/计算器.app", addedAt: 5)
        let rows = QuickSearchFavorites.rows(
            favorites: [favorite], entries: [], recent: [], favoriteLimit: 12, totalLimit: 20
        )
        #expect(rows.map(\.title) == ["计算器"])
        #expect(rows.first?.url.path == "/Applications/计算器.app")
        #expect(rows.first?.kind == .application)
    }

    @Test func aFavoritedAppFollowsItsLiveNameOnceTheIndexIsBack() {
        let favorite = appFavorite("旧名字", bundleID: "com.test.calc", path: "/Applications/Calc.app", addedAt: 5)
        let entry = QuickSearchApplicationEntry(
            url: URL(fileURLWithPath: "/Applications/Calc.app"), name: "新名字", bundleIdentifier: "com.test.calc"
        )
        let rows = QuickSearchFavorites.rows(
            favorites: [favorite], entries: [entry], recent: [], favoriteLimit: 12, totalLimit: 20
        )
        #expect(rows.map(\.title) == ["新名字"])
    }

    @Test func aFavoritedFolderKeepsBeingAFolderRow() {
        let result = QuickSearchResult(
            kind: .folder, title: "截图", subtitle: "/Users/me/Pictures",
            url: URL(fileURLWithPath: "/Users/me/Pictures/截图")
        )
        let rows = QuickSearchFavorites.rows(
            favorites: [QuickSearchFavorite(result: result)], entries: [], recent: [],
            favoriteLimit: 12, totalLimit: 20
        )
        #expect(rows.first?.isFolder == true)
    }

    @Test func onlyTheFirstScreenfulOfFavoritesIsListed() {
        let favorites = (0..<5).map {
            appFavorite("App\($0)", bundleID: "com.test.\($0)", path: "/Applications/\($0).app", addedAt: TimeInterval($0))
        }
        let rows = QuickSearchFavorites.rows(
            favorites: favorites, entries: [], recent: [], favoriteLimit: 2, totalLimit: 20
        )
        #expect(rows.count == 2)
    }

    @Test func recentsStopAtTheTotalLimitWhileFavoritesAreAlreadyCounted() {
        let favorite = appFavorite("A", bundleID: "com.test.a", path: "/Applications/A.app", addedAt: 0)
        let entries = (1..<5).map {
            QuickSearchApplicationEntry(
                url: URL(fileURLWithPath: "/Applications/App\($0).app"), name: "App\($0)", bundleIdentifier: "com.test.\($0)"
            )
        }
        let rows = QuickSearchFavorites.rows(
            favorites: [favorite], entries: entries, recent: entries.map { QuickSearchResult(application: $0) },
            favoriteLimit: 12, totalLimit: 3
        )
        #expect(rows.map(\.title) == ["A", "App1", "App2"])
    }
}
