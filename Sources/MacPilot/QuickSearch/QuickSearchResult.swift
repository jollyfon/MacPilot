//
//  QuickSearchResult.swift
//  MacPilot
//
//  快速搜索的一行结果。应用与文件共用同一个形状，面板只认这一种行，
//  新增提供方不需要改视图。
//

import Foundation

struct QuickSearchResult: Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable, Hashable {
        case application
        case file
        case folder

        var isApplication: Bool { self == .application }
    }

    let id: String
    let kind: Kind
    /// 主标题：应用名或文件名。
    let title: String
    /// 副标题：应用所在目录，或文件所在目录。
    let subtitle: String
    let url: URL
    let bundleIdentifier: String?
    /// Spotlight 给出的内容类型标识符（`public.pdf` 之类），应用为 nil。
    let contentTypeIdentifier: String?
    let modificationDate: Date?

    var isFolder: Bool { kind == .folder }

    /// 面板行上的分类标签。应用与文件共用一行形状，靠这个字段区分。
    var categoryKey: String { kind.titleKey }
    var categorySymbol: String { kind.systemImage }

    /// 图标按这个键去重与缓存：同一 App 的多条结果只取一次图。
    var iconKey: String { url.standardizedFileURL.path }

    init(
        kind: Kind,
        title: String,
        subtitle: String,
        url: URL,
        bundleIdentifier: String? = nil,
        contentTypeIdentifier: String? = nil,
        modificationDate: Date? = nil
    ) {
        self.id = "\(kind.rawValue):\(url.standardizedFileURL.path)"
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.url = url
        self.bundleIdentifier = bundleIdentifier
        self.contentTypeIdentifier = contentTypeIdentifier
        self.modificationDate = modificationDate
    }

    init(file fileHit: QuickSearchFileHit) {
        self.init(
            kind: fileHit.isFolder ? .folder : .file,
            title: fileHit.name,
            subtitle: fileHit.directoryDisplayName,
            url: fileHit.url,
            contentTypeIdentifier: fileHit.contentTypeIdentifier,
            modificationDate: fileHit.modificationDate
        )
    }
}

extension QuickSearchResult.Kind {
    var titleKey: String {
        switch self {
        case .application: "quickSearchKindApplication"
        case .file: "quickSearchKindFile"
        case .folder: "quickSearchKindFolder"
        }
    }

    var systemImage: String {
        switch self {
        case .application: "app.badge"
        case .file: "doc"
        case .folder: "folder"
        }
    }
}
