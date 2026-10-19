//
//  QuickSearchVendorMetadata.swift
//  MacPilot
//
//  只从应用包里读厂商自己写下的说明，不做任何推断：
//  - InternetAccessPolicy.plist / .strings 的 ApplicationDescription；
//  - Info.plist 的 CFBundleGetInfoString；
//  - NSServices 的菜单名（「迅雷下载」这种）；
//  - 英/中本地化的 CFBundleDisplayName、CFBundleName。
//
//  当应用既没有描述也没有用途标签时，才去读本地化 UI 字符串，
//  并且只接受双语词表能确认的概念词；不把整份 UI 文案塞进索引。
//

import Foundation

enum QuickSearchVendorMetadataReader {
    struct LocalizedInfo: Equatable {
        var names: [String] = []
        var descriptions: [String] = []
    }

    /// 应用可能有几十种语言，只读英文与中文；这已经覆盖 macOS 上的中英互搜。
    private static let localizedDirectories = [
        "en.lproj", "en_US.lproj", "en_GB.lproj", "English.lproj", "Base.lproj",
        "zh_CN.lproj", "zh-Hans.lproj", "zh-Hant.lproj", "zh_TW.lproj", "zh_HK.lproj",
    ]

    private static let maximumStringsFileBytes = 192 * 1024
    private static let maximumFallbackTexts = 200
    private static let maximumFallbackBytes = 1_000_000
    private static let maximumFallbackCharacters = 40_000

    static func localizedInfo(fromAppAt url: URL) -> LocalizedInfo {
        let resources = url.appendingPathComponent("Contents/Resources", isDirectory: true)
        var info = LocalizedInfo()
        for directory in localizedDirectories {
            let lproj = resources.appendingPathComponent(directory, isDirectory: true)
            if let strings = stringsDictionary(at: lproj.appendingPathComponent("InfoPlist.strings")) {
                for key in ["CFBundleDisplayName", "CFBundleName"] {
                    if let value = strings[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !value.isEmpty {
                        info.names.append(value)
                    }
                }
            }
            if let strings = stringsDictionary(at: lproj.appendingPathComponent("InternetAccessPolicy.strings")),
               let description = strings["ApplicationDescription"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !description.isEmpty {
                info.descriptions.append(description)
            }
        }
        info.names = deduplicated(info.names)
        info.descriptions = deduplicated(info.descriptions)
        return info
    }

    static func internetAccessPolicyDescription(fromAppAt url: URL) -> String? {
        let resources = url.appendingPathComponent("Contents/Resources", isDirectory: true)
        let plistURL = resources.appendingPathComponent("InternetAccessPolicy.plist")
        guard let data = stringsData(at: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let description = plist["ApplicationDescription"] as? String
        else { return nil }
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 服务菜单名是厂商写的行为声明：迅雷的 `NSMenuItem.default` 就是「迅雷下载」。
    static func serviceNames(from plist: [String: Any]) -> [String] {
        guard let services = plist["NSServices"] as? [[String: Any]] else { return [] }
        var names: [String] = []
        for service in services {
            guard let menu = service["NSMenuItem"] as? [String: Any],
                  let name = menu["default"] as? String
            else { continue }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { names.append(trimmed) }
            if names.count >= 8 { break }
        }
        return deduplicated(names)
    }

    /// CFBundleGetInfoString 常常只是版本号加版权，过滤掉这些噪声；
    /// DBeaver 的 “Universal Database Manager and SQL client.” 这种才保留。
    static func descriptiveGetInfoString(from plist: [String: Any]) -> String? {
        guard let raw = plist["CFBundleGetInfoString"] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return nil }
        let folded = trimmed.lowercased()
        guard !folded.contains("copyright"), !trimmed.contains("©"), !folded.contains("(c)") else { return nil }
        guard trimmed.filter({ $0.isLetter }).count >= 3 else { return nil }
        guard trimmed.contains(where: { $0.isLetter }) else { return nil }
        return trimmed
    }

    /// 没有厂商描述、也没有用途标签时的兜底：读英/中本地化 UI 字符串，
    /// 只把**出现得最多**的概念词交给索引。至少三条文案才算，且第二名要有
    /// 第一名一半的证据量——界面里的「Clean」「Image」按钮不能决定应用用途。
    static func fallbackKeywords(fromAppAt url: URL) -> [String] {
        let resources = url.appendingPathComponent("Contents/Resources", isDirectory: true)
        guard let localeDirectories = try? FileManager.default.contentsOfDirectory(
            at: resources,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let relevant = localeDirectories
            .filter { isEnglishOrChineseLocale($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var texts: [String] = []
        var totalBytes = 0
        var totalCharacters = 0
        for locale in relevant {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: locale,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where file.pathExtension.lowercased() == "strings" {
                guard let values = try? file.resourceValues(forKeys: [.fileSizeKey]),
                      let size = values.fileSize,
                      size > 0, size <= maximumStringsFileBytes
                else { continue }
                guard totalBytes + size <= maximumFallbackBytes else { break }
                totalBytes += size
                autoreleasepool {
                    guard let strings = stringsDictionary(at: file) else { return }
                    // 只取用户可见的 value。key 是开发者的标识符（`clean.button`），
                    // 一条文案算一次证据，不能因为 key/value 各含一次就凑成两条。
                    for (_, value) in strings {
                        if texts.count >= maximumFallbackTexts
                            || totalCharacters >= maximumFallbackCharacters {
                            return
                        }
                        if !value.isEmpty, value.count <= 300 {
                            texts.append(value)
                            totalCharacters += value.count
                        }
                    }
                }
                if texts.count >= maximumFallbackTexts
                    || totalCharacters >= maximumFallbackCharacters {
                    break
                }
            }
            if texts.count >= maximumFallbackTexts
                || totalCharacters >= maximumFallbackCharacters {
                break
            }
        }

        guard !texts.isEmpty else { return [] }
        return QuickSearchKeywordLexicon.dominantKeywords(
            from: texts,
            minimumHits: 3,
            maximumConcepts: 2,
            termsPerConcept: 8
        )
    }

    // MARK: - 文件读取

    private static func stringsDictionary(at url: URL) -> [String: String]? {
        guard let data = stringsData(at: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        var result: [String: String] = [:]
        result.reserveCapacity(plist.count)
        for (key, value) in plist {
            guard let string = value as? String else { continue }
            result[key] = string
        }
        return result
    }

    private static func stringsData(at url: URL) -> Data? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              size > 0, size <= maximumStringsFileBytes
        else { return nil }
        return try? Data(contentsOf: url)
    }

    private static func isEnglishOrChineseLocale(_ directory: String) -> Bool {
        guard directory.lowercased().hasSuffix(".lproj") else { return false }
        let name = directory.dropLast(6).lowercased()
        return name == "en" || name == "base" || name == "english"
            || name.hasPrefix("en_") || name.hasPrefix("en-")
            || name == "zh" || name.hasPrefix("zh_") || name.hasPrefix("zh-")
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { value in
            seen.insert(value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)).inserted
        }
    }
}
