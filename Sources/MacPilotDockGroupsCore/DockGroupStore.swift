//
//  DockGroupStore.swift
//  MacPilotDockGroupsCore
//
//  需求第 6、15、23 节：
//  - 配置统一保存在 `~/Library/Application Support/MacPilot/DockGroups/groups.json`；
//  - 所有写操作先经过 ManagedPathGuard，绝不触碰第三方 App。
//
//  主程序与 Helper 共用本类型。两边都可能编辑配置（Helper 浮层里可以
//  增删 / 排序成员），所以写操作统一走 `update(_:)`：它在跨进程文件锁内
//  重新读取最新文档、应用修改、再原子写回，避免两边的内存副本互相覆盖。
//

import Darwin
import Foundation

public enum DockGroupStoreError: Error, Equatable, LocalizedError {
    case managedPath(ManagedPathError)
    case lockFailure(message: String)

    public var errorDescription: String? {
        switch self {
        case let .managedPath(error): error.localizedDescription
        case let .lockFailure(message): "Could not lock the Dock Groups configuration: \(message)"
        }
    }
}

/// Helper 写完配置后广播给 MacPilot 主程序：主程序据此重新读取分组，
/// 并重建受影响分组的 Helper（成员顺序 / 数量会改变 Dock 上的组合图标）。
///
/// 用分布式通知而不是打开 URL：编辑浮层时 Helper 必须保持 key window，
/// 打开另一个 App 会让浮层失去焦点并被自动关闭。
public enum DockGroupChangeNotifier {
    public static let notificationName = Notification.Name("com.misswell.macpilot.dockgroups.changed")
    public static let groupIDKey = "groupID"

    public static func post(groupID: String) {
        DistributedNotificationCenter.default().postNotificationName(
            notificationName,
            object: nil,
            userInfo: [groupIDKey: groupID],
            deliverImmediately: true
        )
    }
}

public enum DockGroupLoadResult: Equatable {
    case loaded(DockGroupsDocument)
    /// 首次使用：文件尚不存在。
    case missing
    /// 配置损坏：保留损坏文件，返回空文档，让 UI 提示用户而不是崩溃。
    case corrupt(message: String)

    public var document: DockGroupsDocument {
        switch self {
        case let .loaded(document): document
        case .missing, .corrupt: DockGroupsDocument()
        }
    }
}

public struct DockGroupStore: Sendable {
    public let rootDirectory: URL

    public init(rootDirectory: URL = DockGroupPaths.defaultRootDirectory()) {
        self.rootDirectory = rootDirectory
    }

    public var groupsFileURL: URL {
        DockGroupPaths.groupsFile(in: rootDirectory)
    }

    /// 跨进程写锁。放在配置目录内，由主程序与 Helper 共同使用。
    public var lockFileURL: URL {
        rootDirectory.appendingPathComponent(".groups.lock", isDirectory: false)
    }

    /// 读取但不抛错：区分「还没有配置」与「配置损坏」，便于 UI 展示（需求第 16 节的不崩溃原则）。
    public func load() -> DockGroupLoadResult {
        let url = groupsFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            let data = try Data(contentsOf: url)
            let document = try JSONDecoder.dockGroups.decode(DockGroupsDocument.self, from: data)
            return .loaded(document)
        } catch {
            return .corrupt(message: error.localizedDescription)
        }
    }

    /// 写入分组配置。目标路径必须位于管理目录内，否则抛错。
    public func save(_ document: DockGroupsDocument) throws {
        try withExclusiveLock {
            try write(document)
        }
    }

    /// 在写锁内「读取最新文档 → 应用修改 → 原子写回」。
    ///
    /// 这是主程序与 Helper 唯一安全的编辑入口：`mutate` 返回 `false`
    /// 时不写盘（例如重复添加 / 排序位置没变），返回 `nil`。
    /// 配置损坏时从空文档开始，让下一次有效编辑能够恢复文件。
    @discardableResult
    public func update(_ mutate: (inout DockGroupsDocument) -> Bool) throws -> DockGroupsDocument? {
        try withExclusiveLock {
            let current = load().document
            var updated = current
            guard mutate(&updated) else { return nil }
            guard updated != current else { return current }
            try write(updated)
            return updated
        }
    }

    private func write(_ document: DockGroupsDocument) throws {
        let target = try ManagedPathGuard.requireManaged(groupsFileURL, root: rootDirectory)
        try TargetAppAccessPolicy.requireWrite(.write, at: target, managedRoot: rootDirectory)

        let directory = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // 时间戳统一为秒级精度（见 DockGroupTimestamp），
        // 因此 ISO8601 也能精确往返，配置文件保持人类可读。
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)
        try data.write(to: target, options: .atomic)
    }

    /// 阻塞式 `flock`：临界区只有一次毫秒级的读改写，等锁比丢修改更划算。
    private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        let lockURL = try ManagedPathGuard.requireManaged(lockFileURL, root: rootDirectory)
        let directory = lockURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else {
            throw DockGroupStoreError.lockFailure(message: String(cString: strerror(errno)))
        }
        defer { _ = close(descriptor) }

        guard flock(descriptor, LOCK_EX) == 0 else {
            throw DockGroupStoreError.lockFailure(message: String(cString: strerror(errno)))
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    public func group(withID id: String) -> DockGroup? {
        load().document.group(withID: id)
    }

    /// 需求第 26 节：卸载 / 清理时删除 MacPilot 自己的分组配置。
    /// 目标路径同样必须先通过管理目录校验。
    ///
    /// 校验放在「文件是否存在」之前：管理根目录配错时必须如实返回失败，
    /// 而不是因为「本来就没东西可删」就报成功。
    @discardableResult
    public func removeGroupsFile() -> Bool {
        guard let target = try? ManagedPathGuard.requireManaged(groupsFileURL, root: rootDirectory) else {
            return false
        }
        return (try? withExclusiveLock {
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: target.path) else { return true }
            do {
                try fileManager.removeItem(at: target)
                return true
            } catch {
                return false
            }
        }) ?? false
    }

    /// 需求第 26 节：删除 MacPilot 自己拷贝进来的自定义分组图标。
    @discardableResult
    public func removeCustomIcons() -> Bool {
        let icons = rootDirectory.appendingPathComponent("Icons", isDirectory: true)
        guard let target = try? ManagedPathGuard.requireManaged(icons, root: rootDirectory) else {
            return false
        }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: target.path) else { return true }
        do {
            try fileManager.removeItem(at: target)
            return true
        } catch {
            return false
        }
    }

    /// Helper 侧只读入口：拿不到配置时返回 nil（由 Helper 显示未找到提示）。
    public static func group(forHelperBundleIdentifier identifier: String?, rootDirectory: URL = DockGroupPaths.defaultRootDirectory()) -> DockGroup? {
        guard let groupID = DockGroupIdentifier.groupID(fromHelperBundleIdentifier: identifier) else { return nil }
        return DockGroupStore(rootDirectory: rootDirectory).group(withID: groupID)
    }
}

extension JSONDecoder {
    /// groups.json 使用 ISO8601 时间戳（配合 DockGroupTimestamp 的秒级精度）。
    public static var dockGroups: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
