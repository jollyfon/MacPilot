import Foundation
import MacPilotDockGroupsCore
import Testing

/// Dock Groups 核心逻辑：模型编解码、编辑操作、路径守卫与只读策略。
struct DockGroupsCoreTests {

    // MARK: - 编解码

    @Test func groupsDocumentRoundTripsThroughJSON() throws {
        let group = DockGroup(
            id: "dev",
            name: "Dev",
            icon: DockGroupIcon(source: .symbol, value: "hammer"),
            layout: .list,
            apps: [
                DockGroupApp(bundleIdentifier: "com.microsoft.VSCode", path: "/Applications/Visual Studio Code.app", name: "Visual Studio Code"),
                DockGroupApp(bundleIdentifier: "dev.zed.Zed", path: "/Applications/Zed.app", name: "Zed")
            ]
        )
        let document = DockGroupsDocument(groups: [group])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)
        let decoded = try JSONDecoder.dockGroups.decode(DockGroupsDocument.self, from: data)

        #expect(decoded == document)
        #expect(decoded.group(withID: "dev")?.layout == .list)
        #expect(decoded.group(withID: "dev")?.apps.count == 2)
        // 需求第 6 节：bundleIdentifier 是首选解析依据。
        #expect(decoded.group(withID: "dev")?.apps.first?.bundleIdentifier == "com.microsoft.VSCode")
    }

    @Test func unknownGroupIDReturnsNilInsteadOfCrashing() {
        let document = DockGroupsDocument(groups: [DockGroup(id: "dev", name: "Dev")])
        #expect(document.group(withID: "nope") == nil)
    }

    @Test func documentDecodesPartialJSONWithDefaults() throws {
        // 需求第 16 节：配置字段缺失时用默认值补全，而不是解码失败。
        let json = #"{"groups":[{"id":"ai","name":"AI"}]}"#
        let document = try JSONDecoder.dockGroups.decode(DockGroupsDocument.self, from: Data(json.utf8))
        let group = try #require(document.group(withID: "ai"))
        #expect(group.layout == .grid)
        #expect(group.icon.source == .composite)
        #expect(group.apps.isEmpty)
    }

    // MARK: - Bundle ID 规则

    @Test func helperBundleIdentifierRoundTrips() {
        let identifier = DockGroupIdentifier.helperBundleIdentifier(forGroupID: "Dev")
        #expect(identifier == "com.misswell.macpilot.dockgroup.dev")
        #expect(DockGroupIdentifier.groupID(fromHelperBundleIdentifier: identifier) == "dev")
        #expect(DockGroupIdentifier.groupID(fromHelperBundleIdentifier: "com.misswell.macpilot") == nil)
        #expect(DockGroupIdentifier.groupID(fromHelperBundleIdentifier: nil) == nil)
    }

    @Test func groupIDsAreSanitizedAgainstPathTraversal() {
        #expect(DockGroupIdentifier.sanitizedID("../../etc/passwd") == "etc-passwd")
        #expect(DockGroupIdentifier.sanitizedID("Dev Tools") == "dev-tools")
        #expect(DockGroupIdentifier.sanitizedID("  ") == "group")
        #expect(!DockGroupIdentifier.sanitizedID("a/b").contains("/"))
    }

    @Test func helperAppFileNamesCannotEscapeTheManagedDirectory() {
        let root = URL(fileURLWithPath: "/tmp/dockgroups")
        let url = DockGroupPaths.helperAppURL(in: root, groupName: "../../evil")
        #expect(url.path.hasPrefix("/tmp/dockgroups/"))
        #expect(!url.path.contains(".."))
    }

    /// Helper 的 Info.plist 记录成员指纹：增删 / 排序会改变组合图标，
    /// MacPilot 没运行时靠它在下次启动补一次重建。
    @Test func helperMemberSignatureTracksMembershipAndOrder() {
        let safari = DockGroupApp(bundleIdentifier: "com.apple.Safari", path: "/Applications/Safari.app", name: "Safari")
        let notes = DockGroupApp(bundleIdentifier: "com.apple.Notes", path: "/Applications/Notes.app", name: "Notes")
        let preview = DockGroupApp(bundleIdentifier: "com.apple.Preview", path: "/System/Applications/Preview.app", name: "Preview")
        var group = DockGroup(id: "everyday", name: "Everyday", apps: [safari, notes])

        let baseline = DockHelperBundleBuilder.memberSignature(for: group)
        #expect(baseline.count == 64)
        #expect(DockHelperBundleBuilder.memberSignature(for: group) == baseline)

        group.apps.swapAt(0, 1)
        let reordered = DockHelperBundleBuilder.memberSignature(for: group)
        #expect(reordered != baseline)

        group.apps.append(preview)
        #expect(DockHelperBundleBuilder.memberSignature(for: group) != reordered)

        // 同名但不同 ID 的分组生成的是不同的 Helper，指纹也不能撞。
        let renamed = DockGroup(id: "work", name: "Everyday", apps: group.apps)
        #expect(DockHelperBundleBuilder.memberSignature(for: renamed)
            != DockHelperBundleBuilder.memberSignature(for: group))
    }

    // MARK: - Grid 列数

    @Test func gridColumnsAdaptToAppCount() {
        #expect(DockGroupGridMetrics.columns(forAppCount: 0) == 1)
        #expect(DockGroupGridMetrics.columns(forAppCount: 1) == 1)
        #expect(DockGroupGridMetrics.columns(forAppCount: 2) == 2)
        #expect(DockGroupGridMetrics.columns(forAppCount: 4) == 2)
        #expect(DockGroupGridMetrics.columns(forAppCount: 6) == 3)
        #expect(DockGroupGridMetrics.columns(forAppCount: 9) == 3)
        #expect(DockGroupGridMetrics.columns(forAppCount: 16) == 4)
        // 需求第 8 节：最多 4 列。
        #expect(DockGroupGridMetrics.columns(forAppCount: 100) == 4)
    }

    // MARK: - 编辑操作

    @Test func addingTheSameAppTwiceIsRejected() {
        var document = DockGroupsDocument(groups: [DockGroup(id: "dev", name: "Dev")])
        let zed = DockGroupApp(bundleIdentifier: "dev.zed.Zed", path: "/Applications/Zed.app", name: "Zed")
        var duplicate = zed
        duplicate.id = UUID()
        duplicate.path = "/Volumes/Other/Zed.app"

        #expect(DockGroupDocumentEditor.addApp(zed, to: "dev", in: &document))
        // 同一 bundleIdentifier，即使路径不同也不重复添加。
        #expect(!DockGroupDocumentEditor.addApp(duplicate, to: "dev", in: &document))
        #expect(document.groups[0].apps.count == 1)
    }

    @Test func appsWithoutBundleIdentifierFallBackToPathComparison() {
        let left = DockGroupApp(bundleIdentifier: nil, path: "/Applications/Tool.app", name: "Tool")
        var right = left
        right.id = UUID()
        #expect(DockGroupDocumentEditor.isSameApp(left, right))
        right.path = "/Applications/Other.app"
        #expect(!DockGroupDocumentEditor.isSameApp(left, right))
    }

    @Test func movingAppsReordersWithoutLosingThem() {
        var document = DockGroupsDocument(groups: [
            DockGroup(id: "dev", name: "Dev", apps: [
                DockGroupApp(bundleIdentifier: "a", path: "/A.app", name: "A"),
                DockGroupApp(bundleIdentifier: "b", path: "/B.app", name: "B"),
                DockGroupApp(bundleIdentifier: "c", path: "/C.app", name: "C")
            ])
        ])
        #expect(DockGroupDocumentEditor.moveApps(in: "dev", from: IndexSet(integer: 0), to: 3, in: &document))
        #expect(document.groups[0].apps.map(\.name) == ["B", "C", "A"])
    }

    @Test func movingAnAppToATargetIndexUsesTheFinalPosition() {
        var document = DockGroupsDocument(groups: [
            DockGroup(id: "dev", name: "Dev", apps: [
                DockGroupApp(bundleIdentifier: "a", path: "/A.app", name: "A"),
                DockGroupApp(bundleIdentifier: "b", path: "/B.app", name: "B"),
                DockGroupApp(bundleIdentifier: "c", path: "/C.app", name: "C"),
                DockGroupApp(bundleIdentifier: "d", path: "/D.app", name: "D")
            ])
        ])
        let apps = document.groups[0].apps
        // A 拖到 C 的位置：A 落在索引 2。
        #expect(DockGroupDocumentEditor.moveApp(apps[0].id, to: 2, in: "dev", in: &document))
        #expect(document.groups[0].apps.map(\.name) == ["B", "C", "A", "D"])
        // D 拖到最前。
        #expect(DockGroupDocumentEditor.moveApp(apps[3].id, to: 0, in: "dev", in: &document))
        #expect(document.groups[0].apps.map(\.name) == ["D", "B", "C", "A"])
        // 拖到最后一项 = 移到末尾。
        #expect(DockGroupDocumentEditor.moveApp(apps[3].id, to: 3, in: "dev", in: &document))
        #expect(document.groups[0].apps.map(\.name) == ["B", "C", "A", "D"])
        // 位置没变（C 当前就在索引 1，再拖到 1）不写盘。
        #expect(!DockGroupDocumentEditor.moveApp(apps[2].id, to: 1, in: "dev", in: &document))
    }

    @Test func removingAnAppOnlyDeletesTheReference() {
        var document = DockGroupsDocument(groups: [
            DockGroup(id: "dev", name: "Dev", apps: [
                DockGroupApp(bundleIdentifier: "a", path: "/A.app", name: "A"),
                DockGroupApp(bundleIdentifier: "b", path: "/B.app", name: "B")
            ])
        ])
        let removedID = try! #require(document.groups[0].apps.first?.id)
        #expect(DockGroupDocumentEditor.removeApp(removedID, from: "dev", in: &document))
        #expect(document.groups[0].apps.map(\.name) == ["B"])
        #expect(document.groups.count == 1)
    }

    @Test func renamingKeepsGroupNamesUnique() {
        var document = DockGroupsDocument(groups: [
            DockGroup(id: "dev", name: "Dev"),
            DockGroup(id: "tools", name: "Tools")
        ])
        let renamed = DockGroupDocumentEditor.rename(groupID: "tools", to: "Dev", in: &document)
        #expect(renamed == "Dev 2")
        // 重命名自己时不应和自己冲突。
        let same = DockGroupDocumentEditor.rename(groupID: "dev", to: "Dev", in: &document)
        #expect(same == "Dev")
        #expect(DockGroupDocumentEditor.rename(groupID: "dev", to: "   ", in: &document) == nil)
    }

    @Test func creatingGroupsGeneratesStableUniqueIdentifiers() {
        var document = DockGroupsDocument()
        let first = DockGroupDocumentEditor.createGroup(named: "Dev", in: &document)
        let second = DockGroupDocumentEditor.createGroup(named: "Dev", in: &document)
        #expect(first.id == "dev")
        #expect(first.name == "Dev")
        #expect(second.id != first.id)
        #expect(second.name == "Dev 2")
        #expect(document.groups.count == 2)
    }

    @Test func relocatingAnAppKeepsItsIdentityButUpdatesTheReference() {
        var document = DockGroupsDocument(groups: [
            DockGroup(id: "dev", name: "Dev", apps: [
                DockGroupApp(bundleIdentifier: "dev.zed.Zed", path: "/Old/Zed.app", name: "Zed")
            ])
        ])
        let appID = document.groups[0].apps[0].id
        let relocated = DockGroupApp(bundleIdentifier: "dev.zed.Zed", path: "/Applications/Zed.app", name: "Zed")
        #expect(DockGroupDocumentEditor.relocateApp(appID, in: "dev", to: relocated, in: &document))
        #expect(document.groups[0].apps[0].id == appID)
        #expect(document.groups[0].apps[0].path == "/Applications/Zed.app")
    }

    // MARK: - 存储

    @Test func storeRoundTripsGroupsFileInsideManagedRoot() throws {
        let root = try TemporaryDirectory()
        defer { root.cleanUp() }
        let store = DockGroupStore(rootDirectory: root.url)

        #expect(store.load() == .missing)

        let group = DockGroup(id: "ai", name: "AI", apps: [
            DockGroupApp(bundleIdentifier: "com.openai.chat", path: "/Applications/ChatGPT.app", name: "ChatGPT")
        ])
        try store.save(DockGroupsDocument(groups: [group]))

        #expect(store.groupsFileURL.path.hasPrefix(root.url.path))
        let loaded = store.load()
        #expect(loaded.document.groups == [group])
    }

    @Test func corruptGroupsFileIsReportedInsteadOfCrashing() throws {
        let root = try TemporaryDirectory()
        defer { root.cleanUp() }
        let store = DockGroupStore(rootDirectory: root.url)

        try FileManager.default.createDirectory(at: root.url, withIntermediateDirectories: true)
        try Data("{ this is not json".utf8).write(to: store.groupsFileURL)

        guard case .corrupt = store.load() else {
            Issue.record("Expected .corrupt for a malformed groups.json")
            return
        }
        #expect(store.load().document.groups.isEmpty)

        // 损坏后仍然可以重新写入（需求第 16 节：不崩溃、可恢复）。
        try store.save(DockGroupsDocument(groups: [DockGroup(id: "dev", name: "Dev")]))
        #expect(store.load().document.groups.count == 1)
    }

    /// Helper 与主程序是两条独立的写路径：`update` 必须在锁内重新读取磁盘，
    /// 否则两边各自拿着旧副本写回时，总有一边的修改会被覆盖。
    @Test func concurrentUpdatesThroughSeparateStoresRetainEveryChange() throws {
        let root = try TemporaryDirectory()
        defer { root.cleanUp() }
        let bootstrap = DockGroupStore(rootDirectory: root.url)
        try bootstrap.save(DockGroupsDocument(groups: [DockGroup(id: "dev", name: "Dev")]))

        let updates = 40
        let group = DispatchGroup()
        for index in 0..<updates {
            DispatchQueue.global().async(group: group) {
                let store = DockGroupStore(rootDirectory: root.url)
                try? store.update { document in
                    guard let groupIndex = document.groups.firstIndex(where: { $0.id == "dev" }) else {
                        return false
                    }
                    document.groups[groupIndex].apps.append(
                        DockGroupApp(bundleIdentifier: "app.\(index)", path: "/Applications/A\(index).app", name: "A\(index)")
                    )
                    return true
                }
            }
        }
        #expect(group.wait(timeout: .now() + 20) == .success)

        let apps = DockGroupStore(rootDirectory: root.url).load().document.groups.first?.apps ?? []
        #expect(apps.count == updates)
        #expect(Set(apps.map(\.name)).count == updates)
    }

    /// `mutate` 拒绝修改时不能顺手覆盖文件；配置损坏时尤其重要（不能因为
    ///  Helper 打开浮层后什么都没做，就把损坏文件或者别的进程的写入清掉）。
    @Test func aDeclinedUpdateLeavesTheFileUntouched() throws {
        let root = try TemporaryDirectory()
        defer { root.cleanUp() }
        let store = DockGroupStore(rootDirectory: root.url)

        try FileManager.default.createDirectory(at: root.url, withIntermediateDirectories: true)
        let corrupt = Data("{ not json".utf8)
        try corrupt.write(to: store.groupsFileURL)

        #expect(try store.update { _ in false } == nil)
        #expect(try Data(contentsOf: store.groupsFileURL) == corrupt)
    }

    @Test func storeResolvesGroupsByHelperBundleIdentifier() throws {
        let root = try TemporaryDirectory()
        defer { root.cleanUp() }
        let store = DockGroupStore(rootDirectory: root.url)
        try store.save(DockGroupsDocument(groups: [DockGroup(id: "dev", name: "Dev")]))

        let resolved = DockGroupStore.group(
            forHelperBundleIdentifier: "com.misswell.macpilot.dockgroup.dev",
            rootDirectory: root.url
        )
        #expect(resolved?.name == "Dev")
        #expect(DockGroupStore.group(forHelperBundleIdentifier: "com.example.other", rootDirectory: root.url) == nil)
    }

    // MARK: - 路径守卫与只读策略

    @Test func managedPathGuardRejectsForeignPaths() throws {
        let root = try TemporaryDirectory()
        defer { root.cleanUp() }

        #expect(throws: ManagedPathError.self) {
            try ManagedPathGuard.requireManaged(URL(fileURLWithPath: "/Applications/Zed.app"), root: root.url)
        }
        #expect(throws: ManagedPathError.self) {
            try ManagedPathGuard.requireManaged(root.url.deletingLastPathComponent(), root: root.url)
        }
        // 需求第 15 节：管理根目录本身不能是 / 或用户主目录这类宽目录。
        #expect(throws: ManagedPathError.self) {
            try ManagedPathGuard.requireManaged(URL(fileURLWithPath: "/Applications/X.app"), root: URL(fileURLWithPath: "/"))
        }
        let inside = root.url.appendingPathComponent("Dev.app")
        #expect(try ManagedPathGuard.requireManaged(inside, root: root.url) == inside.standardizedFileURL)
    }

    @Test func managedPathGuardRejectsSymbolicLinks() throws {
        let root = try TemporaryDirectory()
        defer { root.cleanUp() }
        let outside = try TemporaryDirectory()
        defer { outside.cleanUp() }

        let link = root.url.appendingPathComponent("Dev.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.url)

        #expect(throws: ManagedPathError.self) {
            try ManagedPathGuard.requireManaged(link, root: root.url)
        }
    }

    /// 需求第 15、26 节：清理入口同样受路径校验保护。
    /// 管理根目录配错成宽目录时，宁可不删也不越界。
    @Test func cleanupRefusesToRunWithABroadManagedRoot() throws {
        let broadRoot = DockGroupStore(rootDirectory: URL(fileURLWithPath: "/Applications"))
        #expect(!broadRoot.removeGroupsFile())
        #expect(!broadRoot.removeCustomIcons())

        // 正常的管理目录：有就删，没有也算成功（幂等）。
        let root = try TemporaryDirectory()
        defer { root.cleanUp() }
        let store = DockGroupStore(rootDirectory: root.url)
        #expect(store.removeGroupsFile())
        #expect(store.removeCustomIcons())
        try store.save(DockGroupsDocument())
        #expect(FileManager.default.fileExists(atPath: store.groupsFileURL.path))
        #expect(store.removeGroupsFile())
        #expect(!FileManager.default.fileExists(atPath: store.groupsFileURL.path))
    }

    /// 需求第 12 节：图标缓存键只由 Bundle ID、版本与尺寸决定，且文件名安全。
    @Test func iconCacheKeysAreSafeFileNames() {
        let key = DockGroupIconCacheKey(
            bundleIdentifier: "../../etc/passwd",
            version: "1.0",
            size: 64
        )
        #expect(!key.fileName.contains("/"))
        #expect(!key.fileName.contains(".."))
        #expect(key.fileName.hasSuffix("@64.png"))
        #expect(key == DockGroupIconCacheKey(bundleIdentifier: "../../etc/passwd", version: "1.0", size: 64))
    }

    @Test func targetAppPolicyDeniesEveryWriteIntent() throws {
        let root = try TemporaryDirectory()
        defer { root.cleanUp() }
        let thirdParty = URL(fileURLWithPath: "/Applications/Zed.app")

        for capability in [TargetAppAccessPolicy.Capability.write, .modify, .replace, .sign, .patch, .inject] {
            let decision = TargetAppAccessPolicy.decide(capability, for: thirdParty, managedRoot: root.url)
            #expect(!decision.isAllowed, "\(capability) must be denied for a third-party app")
            #expect(decision.denialReason != nil)
            #expect(throws: TargetAppAccessPolicy.AccessError.self) {
                try TargetAppAccessPolicy.requireWrite(capability, at: thirdParty, managedRoot: root.url)
            }
        }

        // 只读与启动/激活是允许的。
        #expect(TargetAppAccessPolicy.decide(.read, for: thirdParty, managedRoot: root.url).isAllowed)
        #expect(TargetAppAccessPolicy.decide(.launch, for: thirdParty, managedRoot: root.url).isAllowed)
        #expect(TargetAppAccessPolicy.decide(.activate, for: thirdParty, managedRoot: root.url).isAllowed)
        #expect(TargetAppAccessPolicy.readOnly)

        // MacPilot 自己的产物可以写。
        let managed = try ManagedPathGuard.requireManaged(
            DockGroupPaths.helperAppURL(in: root.url, groupName: "Dev"),
            root: root.url
        )
        #expect(TargetAppAccessPolicy.decide(.write, for: managed, managedRoot: root.url) == .allowedManagedArtifact)
    }

    // MARK: - 引用构造

    /// Helper 浮层新增的编辑入口在两种语言里都必须有真实文案。
    @Test func helperStringsCoverTheEditingActionsInBothLanguages() {
        let keys = ["addApps", "chooseApps", "add", "alreadyInGroup", "saveFailed", "removeFromGroup"]
        for key in keys {
            #expect(DockHelperStrings.value(key, language: .simplifiedChinese) != key, "\(key) is missing Chinese")
            #expect(DockHelperStrings.value(key, language: .english) != key, "\(key) is missing English")
        }
    }

    @Test func nonAppURLsAreNotAcceptedAsReferences() throws {
        let root = try TemporaryDirectory()
        defer { root.cleanUp() }
        let text = root.url.appendingPathComponent("notes.txt")
        try Data("hi".utf8).write(to: text)
        #expect(InstalledAppResolver.makeReference(from: text) == nil)
    }

    @Test func anEmptyLocalizedDisplayNameDoesNotLeaveAnUnnamedReference() throws {
        let root = try TemporaryDirectory()
        defer { root.cleanUp() }
        let app = root.url.appendingPathComponent("SanJuTong.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let english = contents.appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("en.lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: english, withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>CFBundleIdentifier</key><string>com.example.sanjutong</string>
          <key>CFBundleDevelopmentRegion</key><string>en</string>
        </dict></plist>
        """.write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        // 真实存在的包（三局通）把两个名字键都覆盖成空串，而 `Bundle` 读可本地化的键
        // 走的正是这张表：链式 `??` 会停在空值上，索引里留下一条没有名字的应用。
        try "CFBundleDisplayName = \"\";\nCFBundleName = \"\";\n"
            .write(to: english.appendingPathComponent("InfoPlist.strings"), atomically: true, encoding: .utf8)

        #expect((Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)?.isEmpty == true)
        #expect(InstalledAppResolver.makeReference(from: app)?.name == "SanJuTong")
    }
}

// MARK: - 测试辅助

/// 每个测试用独立的临时目录，并在结束时清理。
struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPilotDockGroupsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: url)
    }
}
