//
//  SpotlightFileSearchController.swift
//  MacPilot
//
//  文件名搜索只走 Spotlight（`NSMetadataQuery`），绝不用 FileManager 递归扫盘。
//
//  这里要同时管住四件事：
//  1. `NSMetadataQuery` 是依赖 RunLoop 的对象，只能在主 Actor 上创建、调度和停止，
//     不能塞进不受约束的 detached Task 里；
//  2. 每次查询带一个递增 generation，旧查询的通知与结果必须被丢弃；
//  3. 观察者按 `object: query` 注册，查询结束或取消时同步摘掉，不留悬挂观察者；
//  4. 空结果不等于「没有这个文件」：索引不可用时要说清原因。
//
//  关于第 4 点：macOS 27 上 `NSMetadataQuery` 已经没有 `+supportedScopes` /
//  `+systemSearchScopes` / `+userSearchScopes` 这些类方法（运行时实测不响应），
//  所以「这个范围到底有没有索引」无法同步问出来。可用的公开信号只有：
//  目录是否存在可读、`query.start()` 是否成功，以及**用一条同样走 Spotlight 的
//  宽松探测查询**问一次「这片范围里有没有任何东西」。这里用最后一种来区分
//  「查不了」与「确实没有」。
//

import AppKit
import Foundation

// MARK: - 命中数据

/// Spotlight 返回的一条文件命中。只取展示需要的几个属性，不组装大对象，
/// 也不在这条路径上读文件扩展属性或生成缩略图。
struct QuickSearchFileHit: Sendable, Equatable {
    let url: URL
    let name: String
    let isFolder: Bool
    let contentTypeIdentifier: String?
    let modificationDate: Date?
    let directoryDisplayName: String

    init(
        url: URL,
        name: String? = nil,
        isFolder: Bool,
        contentTypeIdentifier: String? = nil,
        modificationDate: Date? = nil
    ) {
        let standardized = url.standardizedFileURL
        self.url = standardized
        self.name = (name?.isEmpty == false) ? name! : standardized.lastPathComponent
        self.isFolder = isFolder
        self.contentTypeIdentifier = contentTypeIdentifier
        self.modificationDate = modificationDate
        self.directoryDisplayName = standardized.deletingLastPathComponent().lastPathComponent
    }

    var fileExtension: String { url.pathExtension.lowercased() }

    func hasExtension(_ extensionName: String) -> Bool {
        !extensionName.isEmpty && fileExtension == extensionName.lowercased()
    }
}

// MARK: - 索引可用性

/// Spotlight 查不了时的原因。必须把原因显示出来，不能当成「确实没有这个文件」。
enum QuickSearchIndexIssue: Equatable, Sendable {
    /// 探测结果显示这片范围里 Spotlight 给不出任何东西（索引关闭或被排除）。
    case spotlightDisabled
    /// 选定的目录不存在或读不到。
    case selectedScopeNotIndexed([String])
    /// 一个可用范围都没选上（例如选了「指定目录」却还没添加）。
    case noScopeSelected
    /// 查询本身没能跑起来。
    case queryUnavailable

    var messageKey: String {
        switch self {
        case .spotlightDisabled: "quickSearchIndexDisabled"
        case .selectedScopeNotIndexed: "quickSearchIndexScopeMissing"
        case .noScopeSelected: "quickSearchIndexNoScope"
        case .queryUnavailable: "quickSearchIndexUnavailable"
        }
    }
}

enum SpotlightScopeResolution: Equatable, Sendable {
    /// 可用，给出实际要查询的范围。
    case usable([String])
    /// 完全不可用，附原因。
    case unusable(QuickSearchIndexIssue)
}

enum SpotlightScopeResolver {
    /// 把用户选定的范围整理成真正可查询的范围。
    ///
    /// 两种令牌：Apple 的官方 scope 常量（`NSMetadataQueryUserHomeScope` 之类，
    /// 不以 `/` 开头）代表「由 Spotlight 自己决定覆盖哪里」，直接放行；
    /// 目录路径必须存在且可读，否则就是「这个范围没被索引」，不能假装查过了。
    static func resolve(
        requested: [String],
        isUsableDirectory: (String) -> Bool = SpotlightScopeResolver.directoryIsUsable
    ) -> SpotlightScopeResolution {
        var usable: [String] = []
        var missing: [String] = []
        for token in requested where !token.isEmpty {
            guard isPathToken(token) else {
                if !usable.contains(token) { usable.append(token) }
                continue
            }
            let standardized = URL(fileURLWithPath: token).standardizedFileURL.path
            if isUsableDirectory(standardized) {
                if !usable.contains(standardized) { usable.append(standardized) }
            } else if !missing.contains(standardized) {
                missing.append(standardized)
            }
        }
        guard !usable.isEmpty else {
            return .unusable(missing.isEmpty ? .noScopeSelected : .selectedScopeNotIndexed(missing))
        }
        return .usable(usable)
    }

    static func isPathToken(_ token: String) -> Bool {
        token.hasPrefix("/")
    }

    /// 一次 `stat` 级别的检查：存在、是目录、能列出内容。
    /// 不是遍历目录树，自定义目录数量本身有上限。
    private static func directoryIsUsable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        return FileManager.default.isReadableFile(atPath: path)
    }
}

// MARK: - 查询计划

enum SpotlightQueryPlan {
    /// Spotlight 的属性名。写成常量是因为查询按属性名取值，这里要用的是
    /// 索引侧的稳定名字，而不是某个 SDK 版本的 Swift 符号。
    enum Attribute {
        static let path = "kMDItemPath"
        static let filesystemName = "kMDItemFSName"
        static let displayName = "kMDItemDisplayName"
        static let contentType = "kMDItemContentType"
        static let contentTypeTree = "kMDItemContentTypeTree"
        static let contentModificationDate = "kMDItemContentModificationDate"
    }

    /// 用户输入只做「包含」匹配，作用在显示名与实际文件名两列上，
    /// 大小写与音调不敏感。这样「pdf」这类扩展名输入也能命中 `report.pdf`。
    ///
    /// 值一律走 `NSExpression(forConstantValue:)`，不把输入拼进格式字符串，
    /// 避免谓词注入。
    static func namePredicates(matching term: String) -> [NSPredicate] {
        let pattern = "*\(term)*"
        return [
            comparison(attribute: Attribute.displayName, pattern: pattern),
            comparison(attribute: Attribute.filesystemName, pattern: pattern)
        ]
    }

    static func queryPredicate(matching term: String) -> NSPredicate {
        NSCompoundPredicate(orPredicateWithSubpredicates: namePredicates(matching: term))
    }

    /// 探测用的「什么都匹配」谓词：只用来判断这片范围有没有索引，
    /// 结果数量被压到最小，不做展示。
    static func anyIndexedItemPredicate() -> NSPredicate {
        NSCompoundPredicate(orPredicateWithSubpredicates: [
            comparison(attribute: Attribute.displayName, pattern: "*"),
            comparison(attribute: Attribute.filesystemName, pattern: "*")
        ])
    }

    private static func comparison(attribute: String, pattern: String) -> NSPredicate {
        NSComparisonPredicate(
            leftExpression: NSExpression(forKeyPath: attribute),
            rightExpression: NSExpression(forConstantValue: pattern),
            modifier: .direct,
            type: .like,
            options: [.caseInsensitive, .diacriticInsensitive]
        )
    }
}

// MARK: - 查询协议（可注入）

struct QuickSearchFileQueryRequest: Equatable, Sendable {
    let term: String
    let scopes: [String]
    let resultLimit: Int
}

enum QuickSearchFileQueryOutcome: Equatable, Sendable {
    /// 查询有结果回来了，或已结束。`issue` 非空表示是「查不了」，不是「没有」。
    /// 同一个 generation 可能先收到增量结果、再收到结束结果。
    case results(hits: [QuickSearchFileHit], isFinal: Bool, issue: QuickSearchIndexIssue?)
    case cancelled
    case failed(QuickSearchIndexIssue)
}

@MainActor
protocol QuickSearchFileQuerying: AnyObject {
    /// 发起一次查询。回调带上它所属的 generation，调用方据此丢弃过期结果。
    /// 同一实例上再次调用会先终止上一次查询，旧查询不再产生回调。
    func start(
        generation: Int,
        request: QuickSearchFileQueryRequest,
        completion: @escaping @MainActor (Int, QuickSearchFileQueryOutcome) -> Void
    )
    /// 终止当前查询：不再产生结果，观察者同步移除。
    func cancelActiveQuery()
    var hasActiveQuery: Bool { get }
    var trackedObserverCount: Int { get }
}

/// 通知派发闭包运行在 `.main` 队列上，但它的区域不是主 Actor：
/// `Notification` 与 `NSMetadataQuery` 都不能被带进 `MainActor` 的调用里。
/// 只在原地取出可 Sendable 的对象身份，由主 Actor 一侧与当前查询核对。
enum SpotlightNotificationSource {
    nonisolated static func identity(of notification: Notification) -> ObjectIdentifier? {
        (notification.object as? NSMetadataQuery).map(ObjectIdentifier.init)
    }
}

// MARK: - 索引范围探测

@MainActor
protocol SpotlightScopeProbing: AnyObject {
    /// 设置里选定的范围对应的查询令牌（Apple 官方 scope 常量或目录路径）。
    func scopes(for settings: QuickSearchSettings) -> [String]
    /// 判断一批令牌能不能查。
    func resolve(requested: [String]) -> SpotlightScopeResolution
}

@MainActor
final class SystemSpotlightScopeProbe: SpotlightScopeProbing {
    func scopes(for settings: QuickSearchSettings) -> [String] {
        switch settings.fileScope {
        case .home:
            // Apple 官方常量：当前用户的个人目录。
            return [NSMetadataQueryUserHomeScope]
        case .entireMac:
            // 已索引的本地范围。名字里带 Indexed 正是这条需求的重点：
            // 外接盘只在「已经被索引」时才参与，网络卷默认不参与。
            return [NSMetadataQueryIndexedLocalComputerScope]
        case .indexedDirectories:
            return settings.customDirectoryURLs.map { $0.standardizedFileURL.path }
        }
    }

    func resolve(requested: [String]) -> SpotlightScopeResolution {
        SpotlightScopeResolver.resolve(requested: requested)
    }
}

// MARK: - 空结果探测

@MainActor
protocol SpotlightEmptyResultProbing: AnyObject {
    /// 在同一批范围里问一次：Spotlight 能不能给出任何东西。
    ///
    /// - `true`：这片范围有索引，空结果就是「确实没有匹配」。
    /// - `false`：拿不到任何东西，是「查不了」，不能说成「没有文件」。
    /// - `nil`：探测没有结论（超时、查询起不来），调用方不应做任何断言。
    func probe(scopes: [String], completion: @escaping @MainActor (Bool?) -> Void)
    func cancelProbe()
    var trackedObserverCount: Int { get }
}

/// 一次性的宽松 `NSMetadataQuery`：只看「有没有结果」，一有结果立刻收摊。
@MainActor
final class SpotlightEmptyResultProbe: SpotlightEmptyResultProbing {
    /// 探测超时。超时不给结论，而不是猜一个——把「没等到」说成「没索引」同样是骗人。
    static let timeout = Duration.milliseconds(1_200)

    private let observers = ObserverBag()
    private var query: NSMetadataQuery?
    private var activeQueryIdentity: ObjectIdentifier?
    private var completion: (@MainActor (Bool?) -> Void)?
    private var timeoutTask: BackgroundTask?

    var trackedObserverCount: Int { observers.count }

    func probe(scopes: [String], completion: @escaping @MainActor (Bool?) -> Void) {
        cancel()
        guard !scopes.isEmpty else {
            completion(nil)
            return
        }
        let query = NSMetadataQuery()
        query.predicate = SpotlightQueryPlan.anyIndexedItemPredicate()
        query.searchScopes = scopes
        query.sortDescriptors = []
        self.query = query
        activeQueryIdentity = ObjectIdentifier(query)
        self.completion = completion

        let finishToken = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: query,
            queue: .main
        ) { [weak self] notification in
            let identity = SpotlightNotificationSource.identity(of: notification)
            MainActor.assumeIsolated { self?.deliver(fromQueryIdentifiedBy: identity) }
        }
        let updateToken = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidUpdate,
            object: query,
            queue: .main
        ) { [weak self] notification in
            let identity = SpotlightNotificationSource.identity(of: notification)
            MainActor.assumeIsolated { self?.deliver(fromQueryIdentifiedBy: identity) }
        }
        observers.add(finishToken)
        observers.add(updateToken)

        guard query.start() else {
            settle(nil)
            return
        }
        let timeoutTask = BackgroundTask()
        timeoutTask.startOnce(after: Self.timeout) { [weak self] in
            self?.settle(nil)
        }
        self.timeoutTask = timeoutTask
    }

    func cancelProbe() { cancel() }

    private func deliver(fromQueryIdentifiedBy identity: ObjectIdentifier?) {
        guard let sender = query, activeQueryIdentity == identity else { return }
        // 只要看到任何东西，就够回答「这片范围有索引」了。
        guard sender.resultCount > 0 else { return }
        settle(true)
    }

    private func settle(_ verdict: Bool?) {
        let completion = self.completion
        cancel()
        completion?(verdict)
    }

    private func cancel() {
        observers.removeAll()
        query?.stop()
        query = nil
        activeQueryIdentity = nil
        timeoutTask?.stop()
        timeoutTask = nil
        completion = nil
    }
}

// MARK: - Spotlight 实现

/// `NSMetadataQuery` 的生命周期持有者。
@MainActor
final class SpotlightFileSearchController: QuickSearchFileQuerying {
    private let scopeProbe: SpotlightScopeProbing
    private let emptyResultProber: SpotlightEmptyResultProbing
    /// 查询实例的来源。测试注入假查询，才能在不碰真实 Spotlight 的前提下
    /// 验证「空结果 ≠ 没有文件」这条判断链。
    private let queryFactory: @MainActor () -> NSMetadataQuery
    private let observers = ObserverBag()
    private var query: NSMetadataQuery?
    /// 当前查询的身份。通知只在派发它的闭包里读取，跨进主 Actor 时只带这个
    /// Sendable 标识——`NSMetadataQuery` 与 `Notification` 都不该离开原区域。
    private var activeQueryIdentity: ObjectIdentifier?
    private var activeGeneration: Int?
    private var completion: (@MainActor (Int, QuickSearchFileQueryOutcome) -> Void)?
    private var activeScopes: [String] = []
    private var resultLimit = QuickSearchLimits.spotlightResults
    /// 探测结论按范围缓存：连续几次空结果不该每次都重探一遍。
    private var indexVerdicts: [String: Bool] = [:]

    var hasActiveQuery: Bool { query != nil }
    /// 结果查询与探测查询的观察者都算进来：面板关闭后必须归零。
    var trackedObserverCount: Int { observers.count + emptyResultProber.trackedObserverCount }

    init(
        scopeProbe: SpotlightScopeProbing = SystemSpotlightScopeProbe(),
        emptyResultProber: SpotlightEmptyResultProbing? = nil,
        queryFactory: (@MainActor () -> NSMetadataQuery)? = nil
    ) {
        self.scopeProbe = scopeProbe
        self.emptyResultProber = emptyResultProber ?? SpotlightEmptyResultProbe()
        self.queryFactory = queryFactory ?? { NSMetadataQuery() }
    }

    func start(
        generation: Int,
        request: QuickSearchFileQueryRequest,
        completion: @escaping @MainActor (Int, QuickSearchFileQueryOutcome) -> Void
    ) {
        // 新查询到来：先把旧的停干净，包括它的观察者和它的探测。
        terminateActiveQuery()
        guard !request.term.isEmpty else {
            completion(generation, .results(hits: [], isFinal: true, issue: nil))
            return
        }
        switch scopeProbe.resolve(requested: request.scopes) {
        case .usable(let scopes):
            launch(query: queryFactory(), scopes: scopes, request: request, generation: generation, completion: completion)
        case .unusable(let issue):
            completion(generation, .failed(issue))
        }
    }

    /// 在主 Actor 上创建、注册观察者并调度查询。
    private func launch(
        query: NSMetadataQuery,
        scopes: [String],
        request: QuickSearchFileQueryRequest,
        generation: Int,
        completion: @escaping @MainActor (Int, QuickSearchFileQueryOutcome) -> Void
    ) {
        query.predicate = SpotlightQueryPlan.queryPredicate(matching: request.term)
        query.searchScopes = scopes
        query.sortDescriptors = []
        resultLimit = max(1, request.resultLimit)
        self.query = query
        self.activeQueryIdentity = ObjectIdentifier(query)
        self.activeGeneration = generation
        self.completion = completion
        self.activeScopes = scopes

        // 观察者按 object 绑定到这一个查询实例；回调里再用通知自带的对象做一次
        // 身份核对——不捕获 NSMetadataQuery，因为它不是 Sendable，也不该离开主线程。
        let finishToken = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: query,
            queue: .main
        ) { [weak self] notification in
            let identity = SpotlightNotificationSource.identity(of: notification)
            MainActor.assumeIsolated { self?.receive(fromQueryIdentifiedBy: identity, isFinal: true) }
        }
        let updateToken = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidUpdate,
            object: query,
            queue: .main
        ) { [weak self] notification in
            let identity = SpotlightNotificationSource.identity(of: notification)
            MainActor.assumeIsolated { self?.receive(fromQueryIdentifiedBy: identity, isFinal: false) }
        }
        observers.add(finishToken)
        observers.add(updateToken)

        guard query.start() else {
            let completion = self.completion
            terminateActiveQuery()
            completion?(generation, .failed(.queryUnavailable))
            return
        }
    }

    func cancelActiveQuery() {
        guard let generation = activeGeneration else {
            emptyResultProber.cancelProbe()
            return
        }
        let completion = self.completion
        terminateActiveQuery()
        completion?(generation, .cancelled)
    }

    /// 功能停止时用；不留查询、不留观察者、不留回调、不留探测结论。
    func shutdown() {
        terminateActiveQuery()
        indexVerdicts.removeAll()
    }

    // MARK: - 内部

    private func receive(fromQueryIdentifiedBy identity: ObjectIdentifier?, isFinal: Bool) {
        guard let sender = query, activeQueryIdentity == identity, let generation = activeGeneration else { return }
        // 更新期间冻结查询，遍历的是快照副本，避免边读边被查询改动。
        sender.disableUpdates()
        let hits = readHits(from: sender)
        guard isFinal else {
            // 增量更新只为尽早给出首批结果，结束仍以 DidFinishGathering 为准。
            completion?(generation, .results(hits: hits, isFinal: false, issue: nil))
            sender.enableUpdates()
            return
        }
        let scopes = activeScopes
        let completion = self.completion
        terminateActiveQuery()
        guard hits.isEmpty, let completion else {
            completion?(generation, .results(hits: hits, isFinal: true, issue: nil))
            return
        }
        diagnoseEmptyResult(scopes: scopes, generation: generation, completion: completion)
    }

    private func readHits(from query: NSMetadataQuery) -> [QuickSearchFileHit] {
        // `results` 是当前结果的快照副本；配合已冻结的更新可以安全遍历。
        let items = query.results
        let count = min(items.count, resultLimit)
        guard count > 0 else { return [] }
        var hits: [QuickSearchFileHit] = []
        hits.reserveCapacity(count)
        for case let item as NSMetadataItem in items.prefix(count) {
            guard let path = item.value(forAttribute: SpotlightQueryPlan.Attribute.path) as? String,
                  !path.isEmpty else { continue }
            let contentTypes = item.value(forAttribute: SpotlightQueryPlan.Attribute.contentTypeTree) as? [String] ?? []
            hits.append(
                QuickSearchFileHit(
                    url: URL(fileURLWithPath: path),
                    name: item.value(forAttribute: SpotlightQueryPlan.Attribute.filesystemName) as? String,
                    isFolder: contentTypes.contains("public.folder") || contentTypes.contains("public.directory"),
                    contentTypeIdentifier: item.value(forAttribute: SpotlightQueryPlan.Attribute.contentType) as? String,
                    modificationDate: item.value(forAttribute: SpotlightQueryPlan.Attribute.contentModificationDate) as? Date
                )
            )
        }
        return hits
    }

    /// 空结果时区分「真的没有」和「索引不可用」：索引一旦被关掉，前一种说法
    /// 就是在骗用户。探测没有结论时不下断言，只报「没有匹配」。
    private func diagnoseEmptyResult(
        scopes: [String],
        generation: Int,
        completion: @escaping @MainActor (Int, QuickSearchFileQueryOutcome) -> Void
    ) {
        let key = scopes.joined(separator: "\u{1}")
        if let verdict = indexVerdicts[key] {
            completion(generation, .results(hits: [], isFinal: true, issue: verdict ? nil : .spotlightDisabled))
            return
        }
        emptyResultProber.probe(scopes: scopes) { [weak self] verdict in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let verdict { self.indexVerdicts[key] = verdict }
                completion(generation, .results(
                    hits: [],
                    isFinal: true,
                    issue: verdict == false ? .spotlightDisabled : nil
                ))
            }
        }
    }

    private func terminateActiveQuery() {
        // 先摘观察者，再 stop：`stop()` 之后仍可能有排队中的通知派发过来。
        observers.removeAll()
        emptyResultProber.cancelProbe()
        query?.stop()
        query = nil
        activeQueryIdentity = nil
        activeGeneration = nil
        completion = nil
        activeScopes = []
    }
}
