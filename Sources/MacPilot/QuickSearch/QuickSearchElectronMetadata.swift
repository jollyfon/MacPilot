//
//  QuickSearchElectronMetadata.swift
//  MacPilot
//
//  Electron 应用把厂商写的 package.json 封在 app.asar 里。这里只读那一个小文件，
//  不解包、不执行、不联网。
//
//  asar 的头部是一个可能很大的 JSON 文件清单（本机 WorkBuddy 约 3.7 MB），
//  直接 JSONSerialization 会为整棵目录树建对象。这里只扫描根级的 "package.json"
//  条目，再把那几 KB 的 package.json 解析出来。
//

import Foundation

enum QuickSearchElectronMetadataReader {
    struct Metadata: Sendable, Equatable {
        let productName: String?
        let descriptions: [String]
    }

    /// package.json 本身的上限。正常 Electron 包只有几 KB。
    private static let maximumPackageBytes = 1_048_576
    /// asar 头部清单的上限。再大就不是正常应用了。
    private static let maximumHeaderBytes = 24_000_000

    static func read(fromResourcesAt resources: URL) -> Metadata? {
        if let package = packageJSON(inAppDirectoryAt: resources) {
            return metadata(from: package)
        }
        guard let package = packageJSON(fromAsarAt: resources.appendingPathComponent("app.asar")) else {
            return nil
        }
        return metadata(from: package)
    }

    static func metadata(from package: [String: Any]) -> Metadata? {
        var descriptions: [String] = []
        if let description = package["description"] as? String, !description.isEmpty {
            descriptions.append(String(description.prefix(500)))
        }
        if let keywords = package["keywords"] as? [String] {
            let joined = keywords.filter { !$0.isEmpty }.joined(separator: " ")
            if !joined.isEmpty { descriptions.append(String(joined.prefix(500))) }
        } else if let keywords = package["keywords"] as? String, !keywords.isEmpty {
            descriptions.append(String(keywords.prefix(500)))
        }

        let productName = (package["productName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !descriptions.isEmpty || (productName?.isEmpty == false) else { return nil }
        return Metadata(
            productName: productName?.isEmpty == false ? productName : nil,
            descriptions: descriptions
        )
    }

    // MARK: - 普通 app 目录

    private static func packageJSON(inAppDirectoryAt resources: URL) -> [String: Any]? {
        let url = resources.appendingPathComponent("app/package.json")
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              size > 0, size <= maximumPackageBytes,
              let data = try? Data(contentsOf: url)
        else { return nil }
        return jsonObjectDictionary(from: data)
    }

    // MARK: - asar

    static func packageJSON(fromAsarAt url: URL) -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), fileSize >= 16,
              (try? handle.seek(toOffset: 0)) != nil,
              let header = try? handle.read(upToCount: 16), header.count == 16
        else { return nil }

        guard let jsonSize = uint32(in: header, at: 12).map(Int.init),
              let headerSize = uint32(in: header, at: 4).map(Int.init),
              jsonSize > 0, jsonSize <= maximumHeaderBytes,
              headerSize >= jsonSize + 8
        else { return nil }
        let dataStart = 8 + headerSize
        guard dataStart >= 16 + jsonSize, UInt64(dataStart) <= fileSize,
              (try? handle.seek(toOffset: 16)) != nil,
              let headerData = try? handle.read(upToCount: jsonSize),
              headerData.count == jsonSize,
              let entry = rootPackageEntry(in: headerData)
        else { return nil }

        if entry.unpacked {
            let unpacked = url.deletingLastPathComponent()
                .appendingPathComponent("app.asar.unpacked/package.json")
            guard let values = try? unpacked.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize,
                  size > 0, size <= maximumPackageBytes,
                  let data = try? Data(contentsOf: unpacked)
            else { return nil }
            return jsonObjectDictionary(from: data)
        }

        guard entry.size > 0, entry.size <= maximumPackageBytes else { return nil }
        let packageStart = dataStart + entry.offset
        guard packageStart >= dataStart,
              UInt64(packageStart) + UInt64(entry.size) <= fileSize,
              (try? handle.seek(toOffset: UInt64(packageStart))) != nil,
              let packageData = try? handle.read(upToCount: entry.size),
              packageData.count == entry.size
        else { return nil }
        return jsonObjectDictionary(from: packageData)
    }

    private static func jsonObjectDictionary(from data: Data) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return object as? [String: Any]
    }

    struct PackageEntry: Equatable {
        let offset: Int
        let size: Int
        let unpacked: Bool
    }

    /// 只找 `files` 对象根级的 `package.json`。嵌套在 node_modules 里的同名文件
    /// 属于依赖，不是这个应用的厂商描述。
    static func rootPackageEntry(in header: Data) -> PackageEntry? {
        var depth = 0
        var inString = false
        var escaped = false
        var stringStart = -1
        var index = 0

        while index < header.count {
            let byte = header[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                    if depth == 2,
                       isRootPackageName(header, stringStart: stringStart, end: index),
                       let valueStart = valueStart(afterKeyEndingAt: index, in: header),
                       let valueEnd = objectEnd(in: header, startingAt: valueStart),
                       let object = jsonObjectDictionary(
                           from: header.subdata(in: valueStart..<(valueEnd + 1))
                       ),
                       let entry = packageEntry(from: object) {
                        return entry
                    }
                }
            } else {
                switch byte {
                case 0x22:
                    inString = true
                    stringStart = index + 1
                case 0x7B, 0x5B:
                    depth += 1
                case 0x7D, 0x5D:
                    depth -= 1
                default:
                    break
                }
            }
            index += 1
        }
        return nil
    }

    private static func isRootPackageName(_ data: Data, stringStart: Int, end: Int) -> Bool {
        let name = Array("package.json".utf8)
        guard stringStart >= 0, end - stringStart == name.count else { return false }
        for offset in 0..<name.count where data[stringStart + offset] != name[offset] {
            return false
        }
        return true
    }

    private static func valueStart(afterKeyEndingAt end: Int, in data: Data) -> Int? {
        var index = end + 1
        while index < data.count, isJSONWhitespace(data[index]) { index += 1 }
        guard index < data.count, data[index] == 0x3A else { return nil }
        index += 1
        while index < data.count, isJSONWhitespace(data[index]) { index += 1 }
        guard index < data.count, data[index] == 0x7B else { return nil }
        return index
    }

    private static func objectEnd(in data: Data, startingAt start: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < data.count {
            let byte = data[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                }
            } else {
                switch byte {
                case 0x22:
                    inString = true
                case 0x7B, 0x5B:
                    depth += 1
                case 0x7D, 0x5D:
                    depth -= 1
                    if depth == 0 { return index }
                default:
                    break
                }
            }
            index += 1
        }
        return nil
    }

    private static func packageEntry(from object: [String: Any]) -> PackageEntry? {
        let size: Int
        if let number = object["size"] as? NSNumber {
            size = number.intValue
        } else if let value = object["size"] as? Int {
            size = value
        } else {
            return nil
        }

        let offset: Int
        if let string = object["offset"] as? String, let value = Int(string) {
            offset = value
        } else if let number = object["offset"] as? NSNumber {
            offset = number.intValue
        } else if let value = object["offset"] as? Int {
            offset = value
        } else {
            return nil
        }

        guard size >= 0, offset >= 0 else { return nil }
        return PackageEntry(
            offset: offset,
            size: size,
            unpacked: (object["unpacked"] as? Bool) ?? false
        )
    }

    private static func uint32(in data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
    }
}
