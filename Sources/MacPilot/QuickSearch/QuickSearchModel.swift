//
//  QuickSearchModel.swift
//  MacPilot
//
//  快速搜索的功能模型：生命周期、设置、全局快捷键、面板控制、应用启动与文件打开。
//
//  三条硬约束：
//  1. 初始化阶段不同步扫盘、不建 UI、不起 Spotlight——都在 start() 之后按需发生；
//  2. 每次搜索带递增 generation，旧查询的结果不能覆盖新结果，面板关闭即失效；
//  3. stop() 必须同步完成清理，`willTerminate` 不会等异步 Task。
//

import AppKit
import Combine
import Foundation
import MacPilotDockGroupsCore
import os

// MARK: - 可注入的外部动作

/// 启动/激活应用。默认实现直接调用 Dock Groups 已有的 `AppLaunchService`，
/// 这里只负责把它的错误翻译成可显示的失败原因。
@MainActor
protocol QuickSearchLaunching: AnyObject {
    /// 成功返回 nil；失败返回原因。
    func open(applicationAt url: URL, name: String) async -> QuickSearchFailure?
}

/// 打开文件与在 Finder 中显示。
@MainActor
protocol QuickSearchFileOpening: AnyObject {
    func open(_ url: URL) -> QuickSearchFailure?
    func revealInFinder(_ url: URL) -> QuickSearchFailure?
}

/// 目标是否还在。打开前先确认，卸载/移动/删除不该表现为「一切正常」。
@MainActor
protocol QuickSearchItemAvailability: AnyObject {
    func exists(at url: URL) -> Bool
}

enum QuickSearchFailure: Equatable, Sendable {
    case applicationMissing(name: String)
    case launchFailed(name: String)
    case itemMissing(name: String)
    case openFailed(name: String)
    case revealFailed(name: String)
    case cloudItemUnavailable(name: String)

    var messageKey: String {
        switch self {
        case .applicationMissing: "quickSearchErrorApplicationMissing"
        case .launchFailed: "quickSearchErrorLaunchFailed"
        case .itemMissing: "quickSearchErrorItemMissing"
        case .openFailed: "quickSearchErrorOpenFailed"
        case .revealFailed: "quickSearchErrorRevealFailed"
        case .cloudItemUnavailable: "quickSearchErrorCloudUnavailable"
        }
    }

    var argument: String {
        switch self {
        case .applicationMissing(let name), .launchFailed(let name), .itemMissing(let name),
             .openFailed(let name), .revealFailed(let name), .cloudItemUnavailable(let name):
            return name
        }
    }
}

// MARK: - 模型

@MainActor
final class QuickSearchModel: ObservableObject, ManagedFeature, FeatureResourceReporting {
    /// 功能本身的运行状态。
    enum RuntimeState: Equatable {
        case disabled
        case starting
        case ready
        case stopping
    }

    /// 面板的显示状态。**与运行状态分开**：功能在跑不代表面板开着，面板开着也不代表
    /// 正在搜索。
    enum Presentation: Equatable {
        case hidden
        case visible
    }

    /// 文件查询的进行状态。
    enum SearchPhase: Equatable {
        case idle
        case debouncing
        case queryingSpotlight
    }

    /// 设置页与诊断要展示的合并视图（AGENTS.md「生命周期状态」一节）。
    enum LifecycleState: Equatable {
        case disabled, starting, ready, presenting, searching, stopping
    }

    let identifier = "quickSearch"
    private static let logger = Logger(subsystem: "com.misswell.macpilot", category: "QuickSearch")

    @Published private(set) var settings = QuickSearchSettings()
    @Published private(set) var runtimeState: RuntimeState = .disabled
    @Published private(set) var presentation: Presentation = .hidden
    @Published private(set) var searchPhase: SearchPhase = .idle
    @Published private(set) var query = ""
    @Published private(set) var applicationResults: [QuickSearchResult] = []
    @Published private(set) var fileResults: [QuickSearchResult] = []
    @Published private(set) var selectedRowIndex: Int = 0
    /// Spotlight 查不了的原因。有值时必须显示出来，不能显示成「没有结果」。
    @Published private(set) var fileSearchIssue: QuickSearchIndexIssue?
    /// 快捷键注册或清理的错误/警告；实际注册状态由 `isHotKeyRegistered` 表示。
    @Published private(set) var hotKeyError: QuickSearchHotKeyError?
    /// 一次性错误提示（面板已关闭后的失败反馈）。
    @Published private(set) var transientNotice: String?
    @Published private(set) var indexState: ApplicationInventory.State = .empty
    @Published private(set) var indexEntryCount = 0

    var language: AppLanguage = .system
    var persist: (() -> Void)?
    /// 由 MacPilotModel 注入：这个组合是否已被 MacPilot 内其它功能占用。
    var shortcutConflictChecker: (@MainActor (SmartCaptureShortcutBinding) -> String?)?
    /// 由测试注入：用不显示真实窗口的替身验证生命周期，避免自动化测试抢占用户焦点。
    var panelFactory: (@MainActor (@escaping () -> Void) -> QuickSearchPanelPresenting)?
    /// 由测试注入：失败提示同样是一个真窗口，测试里不该在用户桌面上闪一下。
    var noticePanelFactory: (@MainActor () -> QuickSearchNoticePresenting)?
    /// 由测试注入：手动放行文件查询防抖。同一进程里其它 @MainActor 套件会把主 Actor
    /// 队列堵上一两分钟，靠墙钟计时的用例在那种环境下只会误报。
    var fileDebounceScheduler: (@MainActor (Duration, @escaping @MainActor () -> Void) -> Void)?

    let inventory: ApplicationInventory
    let icons: QuickSearchIconLoader
    let usage: QuickSearchUsageStore

    private let fileQuery: QuickSearchFileQuerying
    private let scopeProbe: SpotlightScopeProbing
    private let launcher: QuickSearchLaunching
    private let fileOpener: QuickSearchFileOpening
    private let availability: QuickSearchItemAvailability
    private let hotKeyCenter: QuickSearchHotKeyCenter
    private let fileDebounceTask = BackgroundTask()
    private let noticeDismissTask = BackgroundTask()

    private var panel: QuickSearchPanelPresenting?
    private var noticePanel: QuickSearchNoticePresenting?
    private var searchGeneration = 0

    var isRunning: Bool { runtimeState == .ready || runtimeState == .starting }
    var isPanelVisible: Bool { presentation == .visible }
    /// 快捷键此刻到底注册上了没有。设置页用它说明「能用」还是「不能用」，
    /// 而不是只看有没有报错——注册失败却显示成正常启用是最糟的假状态。
    var isHotKeyRegistered: Bool { hotKeyCenter.isRegistered }

    /// 面板显示的行：应用在前、文件在后，合计不超过展示上界。
    /// 计算属性每次求值顺序一致，选中下标始终指向同一行。
    var results: [QuickSearchResult] {
        Array((applicationResults + fileResults).prefix(QuickSearchLimits.visibleResults))
    }

    var lifecycleState: LifecycleState {
        switch runtimeState {
        case .disabled: return .disabled
        case .starting: return .starting
        case .stopping: return .stopping
        case .ready:
            if searchPhase != .idle { return .searching }
            return presentation == .visible ? .presenting : .ready
        }
    }

    var diagnosticTaskCount: Int {
        (fileDebounceTask.isRunning ? 1 : 0)
            + (noticeDismissTask.isRunning ? 1 : 0)
            + (inventory.isScanning ? 1 : 0)
            + icons.diagnosticTaskCount
    }
    var diagnosticObserverCount: Int { fileQuery.trackedObserverCount }

    init(
        inventory: ApplicationInventory? = nil,
        icons: QuickSearchIconLoader? = nil,
        usage: QuickSearchUsageStore? = nil,
        fileQuery: QuickSearchFileQuerying? = nil,
        scopeProbe: SpotlightScopeProbing? = nil,
        launcher: QuickSearchLaunching? = nil,
        fileOpener: QuickSearchFileOpening? = nil,
        availability: QuickSearchItemAvailability? = nil,
        hotKeyCenter: QuickSearchHotKeyCenter? = nil
    ) {
        let inventory = inventory ?? ApplicationInventory()
        self.inventory = inventory
        self.hotKeyCenter = hotKeyCenter ?? QuickSearchHotKeyCenter()
        self.icons = icons ?? QuickSearchIconLoader()
        self.usage = usage ?? QuickSearchUsageStore()
        let probe = scopeProbe ?? SystemSpotlightScopeProbe()
        self.scopeProbe = probe
        // 默认查询器与探测用同一个 scope 来源，避免两边判断对不上。
        self.fileQuery = fileQuery ?? SpotlightFileSearchController(scopeProbe: probe)
        self.launcher = launcher ?? SystemApplicationLauncher()
        self.fileOpener = fileOpener ?? SystemFileOpener()
        self.availability = availability ?? FileSystemItemAvailability()
        // 后台构建落地时刷新计数，并把当前查询补上：首次呼出时索引往往还在建。
        inventory.onIndexRebuilt = { [weak self] in self?.handleIndexRebuilt() }
    }

    /// 索引构建完成：刷新展示计数；面板开着时按当前输入重跑一次应用搜索。
    private func handleIndexRebuilt() {
        publishIndexState()
        guard presentation == .visible else { return }
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            showRecentApplications()
        } else {
            runApplicationSearch()
        }
        trimSelectionIndex()
    }

    // MARK: - ManagedFeature

    func start() {
        guard runtimeState == .disabled || runtimeState == .stopping else { return }
        runtimeState = .starting
        hotKeyCenter.conflictChecker = shortcutConflictChecker
        hotKeyCenter.onToggle = { [weak self] in self?.togglePanel() }
        hotKeyError = hotKeyCenter.updateBinding(settings.hotkey) ?? hotKeyCenter.lastError
        icons.startMemoryPressureHandling()
        inventory.extraDirectories = settings.customDirectoryPaths
        runtimeState = .ready
        indexState = inventory.state
    }

    func stop() { shutdown() }

    /// 同步清理：快捷键、查询、面板、索引缓存、图标缓存全部当场归还。
    func shutdown() {
        guard runtimeState != .disabled else {
            hotKeyCenter.stop()
            hotKeyError = hotKeyCenter.lastError
            closePanel()
            return
        }
        runtimeState = .stopping
        invalidateFileSearch()
        hotKeyCenter.stop()
        hotKeyError = hotKeyCenter.lastError
        closePanel()
        dismissNoticeNow()
        clearResults(keepIndex: false)
        inventory.shutdown()
        icons.stop()
        searchPhase = .idle
        presentation = .hidden
        runtimeState = .disabled
        indexState = inventory.state
        indexEntryCount = 0
    }

    func applyLoadedSettings(_ loaded: QuickSearchSettings, activate: Bool = false) {
        settings = loaded
        inventory.extraDirectories = loaded.customDirectoryPaths
        if activate && loaded.isEnabled { start() }
    }

    func t(_ key: String, _ arguments: CVarArg...) -> String {
        AppText.value(key, language: language, arguments: arguments)
    }

    // MARK: - 设置改动

    /// 首页开关的运行时镜像。
    func setEnabled(_ enabled: Bool) {
        guard settings.isEnabled != enabled else { return }
        settings.isEnabled = enabled
        if enabled {
            start()
        } else {
            shutdown()
        }
        persist?()
    }

    /// 改快捷键。无效或注册失败都保留原绑定并说明原因——不能悄悄改掉用户的选择。
    func setHotkey(_ binding: SmartCaptureShortcutBinding) {
        let bindingChanged = binding != settings.hotkey
        guard bindingChanged || hotKeyError != nil || hotKeyCenter.lastError != nil else { return }
        guard binding.isValid else {
            hotKeyError = .invalidBinding
            return
        }
        if isRunning {
            hotKeyCenter.conflictChecker = shortcutConflictChecker
            let error = hotKeyCenter.updateBinding(binding)
            hotKeyError = error ?? hotKeyCenter.lastError
            guard error == nil else { return }
            if bindingChanged { settings.hotkey = binding }
        } else {
            hotKeyCenter.stop()
            guard !hotKeyCenter.hasUnreleasedHotKeys else {
                hotKeyError = hotKeyCenter.lastError
                return
            }
            if bindingChanged { settings.hotkey = binding }
            hotKeyError = hotKeyCenter.lastError
        }
        if bindingChanged { persist?() }
    }

    func setFileScope(_ scope: QuickSearchFileScope) {
        guard settings.fileScope != scope else { return }
        settings.fileScope = scope
        fileSearchIssue = nil
        persist?()
    }

    func addCustomDirectory(path: String) {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard !standardized.isEmpty, !settings.customDirectoryPaths.contains(standardized) else { return }
        var paths = settings.customDirectoryPaths
        paths.append(standardized)
        if paths.count > QuickSearchLimits.customDirectories {
            paths = Array(paths.sorted().prefix(QuickSearchLimits.customDirectories))
        } else {
            paths.sort()
        }
        settings.customDirectoryPaths = paths
        inventory.extraDirectories = paths
        persist?()
    }

    func removeCustomDirectory(path: String) {
        guard settings.customDirectoryPaths.contains(path) else { return }
        settings.customDirectoryPaths.removeAll { $0 == path }
        inventory.extraDirectories = settings.customDirectoryPaths
        persist?()
    }

    /// 手动刷新应用列表。
    func refreshApplicationIndex() {
        guard isRunning else { return }
        inventory.rebuild()
        indexState = inventory.state
    }

    // MARK: - 面板

    func togglePanel() {
        if isPanelVisible {
            closePanel()
        } else {
            openPanel()
        }
    }

    func openPanel() {
        guard settings.isEnabled, runtimeState == .ready else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        query = ""
        selectedRowIndex = 0
        fileSearchIssue = nil
        showRecentApplications()
        inventory.syncRunningState()
        inventory.refreshIfStale()
        publishIndexState()
        presentation = .visible
        panel.open()
    }

    func closePanel() {
        invalidateFileSearch()
        panel?.close()
        panel = nil
        if presentation == .visible { presentation = .hidden }
        // 面板关掉只收起 UI：轻量应用索引留着，下次呼出直接可用。
        clearResults(keepIndex: true)
        query = ""
        selectedRowIndex = 0
    }

    private func makePanel() -> QuickSearchPanelPresenting {
        let close: () -> Void = { [weak self] in
            guard let self else { return }
            self.handlePanelClosed()
        }
        if let panelFactory { return panelFactory(close) }
        return QuickSearchPanel(model: self, onClose: close)
    }

    private func handlePanelClosed() {
        invalidateFileSearch()
        panel = nil
        if presentation == .visible { presentation = .hidden }
        clearResults(keepIndex: true)
        query = ""
        selectedRowIndex = 0
    }

    // MARK: - 搜索

    /// 输入变化：应用结果立刻出（走内存索引），文件查询进防抖。
    func updateQuery(_ text: String) {
        searchGeneration &+= 1
        query = text
        selectedRowIndex = 0
        fileSearchIssue = nil
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fileDebounceTask.stop()
            fileQuery.cancelActiveQuery()
            fileResults = []
            searchPhase = .idle
            showRecentApplications()
            return
        }
        runApplicationSearch()
        scheduleFileSearch(for: text)
    }

    private func runApplicationSearch() {
        applicationResults = ApplicationSearchProvider.search(
            query: query,
            entries: inventory.entries,
            usage: { [weak self] entry in self?.usage.count(for: entry) ?? 0 },
            limit: QuickSearchLimits.applicationResults
        )
    }

    private func showRecentApplications() {
        applicationResults = ApplicationSearchProvider.recentApplications(
            entries: inventory.entries,
            recentIdentities: usage.recentIdentities(limit: QuickSearchLimits.recentApplications),
            limit: QuickSearchLimits.recentApplications
        )
        fileResults = []
    }

    private func scheduleFileSearch(for text: String) {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        fileDebounceTask.stop()
        guard term.count >= QuickSearchLimits.minimumFileQueryCharacters else {
            // 单字符交给 Spotlight 会是海量结果；直接不给文件结果。
            fileResults = []
            fileSearchIssue = nil
            searchPhase = .idle
            return
        }
        searchPhase = .debouncing
        let generation = searchGeneration
        let delay = Duration.milliseconds(QuickSearchLimits.debounceMilliseconds)
        let work: @MainActor () -> Void = { [weak self] in
            self?.startFileSearch(generation: generation, term: term)
        }
        if let fileDebounceScheduler {
            // 过期generation由 startFileSearch 自己判掉：这里放行的是「登记过的每一次输入」。
            fileDebounceScheduler(delay, work)
            return
        }
        fileDebounceTask.startOnce(after: delay, action: work)
    }

    private func startFileSearch(generation: Int, term: String) {
        guard isRunning, presentation == .visible, generation == searchGeneration else { return }
        let scopes = scopeProbe.scopes(for: settings)
        // 范围不可用时不发起查询：让 Spotlight 自己兜底会悄悄扩大到用户没选的地方，
        // 之后那句「没有匹配的文件」就成了假话。这里直接说明原因。
        guard !scopes.isEmpty else {
            fileResults = []
            fileSearchIssue = .noScopeSelected
            searchPhase = .idle
            return
        }
        searchPhase = .queryingSpotlight
        fileQuery.start(
            generation: generation,
            request: QuickSearchFileQueryRequest(
                term: term,
                scopes: scopes,
                resultLimit: QuickSearchLimits.spotlightResults
            )
        ) { [weak self] returnedGeneration, outcome in
            self?.receive(outcome, generation: returnedGeneration)
        }
    }

    private func receive(_ outcome: QuickSearchFileQueryOutcome, generation: Int) {
        // 只处理当前这一次查询：旧查询晚到的结果不能覆盖新结果。
        guard generation == searchGeneration else { return }
        switch outcome {
        case .results(let hits, let isFinal, let issue):
            fileResults = hits.prefix(QuickSearchLimits.visibleResults).map { QuickSearchResult(file: $0) }
            fileSearchIssue = issue
            searchPhase = isFinal ? .idle : .queryingSpotlight
        case .failed(let issue):
            fileResults = []
            fileSearchIssue = issue
            searchPhase = .idle
        case .cancelled:
            searchPhase = .idle
        }
        trimSelectionIndex()
    }

    private func invalidateFileSearch() {
        searchGeneration &+= 1
        fileDebounceTask.stop()
        fileQuery.cancelActiveQuery()
        searchPhase = .idle
    }

    private func clearResults(keepIndex: Bool) {
        applicationResults = []
        fileResults = []
        fileSearchIssue = nil
        if !keepIndex { indexEntryCount = 0 }
    }

    func publishIndexState() {
        indexState = inventory.state
        indexEntryCount = inventory.entryCount
    }

    // MARK: - 选择与执行

    func moveSelection(by delta: Int) {
        let rows = results.count
        guard rows > 0 else { selectedRowIndex = 0; return }
        selectedRowIndex = min(max(selectedRowIndex + delta, 0), rows - 1)
    }

    /// 鼠标悬停/点击直接指定行。越界下标不改变当前选择。
    func selectRow(at index: Int) {
        guard results.indices.contains(index) else { return }
        selectedRowIndex = index
    }

    private func trimSelectionIndex() {
        selectedRowIndex = min(selectedRowIndex, max(results.count - 1, 0))
    }

    var currentSelection: QuickSearchResult? {
        guard results.indices.contains(selectedRowIndex) else { return nil }
        return results[selectedRowIndex]
    }

    /// Enter：应用启动/激活，文件打开。
    func performPrimaryAction(on result: QuickSearchResult? = nil) {
        guard let target = result ?? currentSelection else { return }
        let displayName = target.title
        guard availability.exists(at: target.url) else {
            closePanel()
            presentNotice(t("quickSearchErrorItemMissing", displayName))
            return
        }
        // 先收面板，再执行：启动过程不该被一个还悬在前台的搜索框挡住。
        closePanel()
        switch target.kind {
        case .application:
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let failure = await self.launcher.open(applicationAt: target.url, name: displayName) {
                    self.presentNotice(self.t(failure.messageKey, failure.argument))
                    return
                }
                self.recordUsage(of: target)
            }
        case .file, .folder:
            if let failure = fileOpener.open(target.url) {
                presentNotice(t(failure.messageKey, failure.argument))
            }
        }
    }

    /// Command + Enter：在 Finder 中显示。
    func revealSelectionInFinder(on result: QuickSearchResult? = nil) {
        guard let target = result ?? currentSelection else { return }
        let displayName = target.title
        guard availability.exists(at: target.url) else {
            closePanel()
            presentNotice(t("quickSearchErrorItemMissing", displayName))
            return
        }
        closePanel()
        if let failure = fileOpener.revealInFinder(target.url) {
            presentNotice(t(failure.messageKey, failure.argument))
        }
    }

    func activate(resultID id: String) {
        guard let target = results.first(where: { $0.id == id }) else { return }
        performPrimaryAction(on: target)
    }

    func reveal(resultID id: String) {
        guard let target = results.first(where: { $0.id == id }) else { return }
        revealSelectionInFinder(on: target)
    }

    private func recordUsage(of result: QuickSearchResult) {
        guard let entry = inventory.entries.first(where: { $0.id == result.url.standardizedFileURL.path }) else {
            return
        }
        usage.recordLaunch(of: entry)
    }

    // MARK: - 错误提示

    private func presentNotice(_ text: String) {
        noticeDismissTask.stop()
        let panel = noticePanel ?? noticePanelFactory?() ?? QuickSearchNoticePanel()
        noticePanel = panel
        panel.present(text)
        transientNotice = text
        noticeDismissTask.startOnce(after: .seconds(2.6)) { [weak self] in
            self?.dismissNoticeNow()
        }
    }

    private func dismissNoticeNow() {
        noticeDismissTask.stop()
        noticePanel?.dismiss()
        noticePanel = nil
        transientNotice = nil
    }

    // MARK: - 图标

    func icon(for result: QuickSearchResult) -> NSImage? {
        icons.icon(for: result.url, pointSize: 32, key: result.iconKey)
    }

    var iconRevision: Int { icons.revision }
}

// MARK: - 默认实现

/// 复用 Dock Groups 的启动服务：运行中激活、未运行启动，不重复开第二个实例。
@MainActor
final class SystemApplicationLauncher: QuickSearchLaunching {
    private static let logger = Logger(subsystem: "com.misswell.macpilot", category: "QuickSearchLaunch")

    func open(applicationAt url: URL, name: String) async -> QuickSearchFailure? {
        do {
            _ = try await AppLaunchService.open(url: url, name: name)
            return nil
        } catch let error as AppLaunchError {
            switch error {
            case .applicationNotFound: return .applicationMissing(name: name)
            case .launchFailed: return .launchFailed(name: name)
            case .activationFailed: return .launchFailed(name: name)
            }
        } catch {
            Self.logger.notice("QuickSearch launch of \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return .launchFailed(name: name)
        }
    }
}

@MainActor
final class SystemFileOpener: QuickSearchFileOpening {
    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    func open(_ url: URL) -> QuickSearchFailure? {
        let name = url.lastPathComponent
        guard workspace.open(url) else { return .openFailed(name: name) }
        return nil
    }

    func revealInFinder(_ url: URL) -> QuickSearchFailure? {
        workspace.activateFileViewerSelecting([url])
        return nil
    }
}

@MainActor
final class FileSystemItemAvailability: QuickSearchItemAvailability {
    func exists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
