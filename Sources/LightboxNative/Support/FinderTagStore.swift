import Foundation
import Darwin

enum FinderTagStore {
    private static let userTagsAttribute = "com.apple.metadata:_kMDItemUserTags"
    private static let colorTagTokens: [String: String] = [
        "Red": "Red\n6",
        "Orange": "Orange\n7",
        "Yellow": "Yellow\n5",
        "Green": "Green\n2",
        "Blue": "Blue\n4",
        "Purple": "Purple\n3",
        "Gray": "Gray\n1"
    ]
    private static let colorCodeNames: [String: String] = [
        "6": "Red",
        "7": "Orange",
        "5": "Yellow",
        "2": "Green",
        "4": "Blue",
        "3": "Purple",
        "1": "Gray"
    ]
    private static let localizedColorNames: [String: String] = [
        "红色": "Red",
        "紅色": "Red",
        "赤": "Red",
        "橙色": "Orange",
        "オレンジ": "Orange",
        "黄色": "Yellow",
        "黄": "Yellow",
        "绿色": "Green",
        "綠色": "Green",
        "緑": "Green",
        "蓝色": "Blue",
        "藍色": "Blue",
        "青": "Blue",
        "紫色": "Purple",
        "紫": "Purple",
        "灰色": "Gray",
        "グレイ": "Gray",
        "グレー": "Gray"
    ]

    static func colorTags(for url: URL) -> [String] {
        let xattrTags = rawUserTags(for: url)
        let tags = xattrTags.compactMap { colorTagName(from: $0) }
        return MacColorTag.sort(Array(Set(tags)))
    }

    static func setColorTags(_ colorTags: [String], for url: URL) -> Bool {
        let sortedColorTags = MacColorTag.sort(colorTags.filter(MacColorTag.isColorTag))
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let existingTags = rawUserTags(for: url)
            let nonColorTags = existingTags.filter { colorTagName(from: $0) == nil }
            let nextTags = nonColorTags + sortedColorTags.compactMap { colorTagTokens[$0] }
            try writeRawUserTags(nextTags, to: url)
            return true
        } catch {
            return false
        }
    }

    private static func rawUserTags(for url: URL) -> [String] {
        let path = url.path
        let size = getxattr(path, userTagsAttribute, nil, 0, 0, 0)
        guard size > 0 else {
            return []
        }

        var data = Data(count: size)
        let readSize = data.withUnsafeMutableBytes { buffer in
            getxattr(path, userTagsAttribute, buffer.baseAddress, size, 0, 0)
        }
        guard readSize > 0 else {
            return []
        }

        if readSize < data.count {
            data.removeSubrange(readSize..<data.count)
        }

        guard let tags = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String] else {
            return []
        }

        return tags
    }

    private static func writeRawUserTags(_ tags: [String], to url: URL) throws {
        if tags.isEmpty {
            removexattr(url.path, userTagsAttribute, 0)
            return
        }

        let data = try PropertyListSerialization.data(
            fromPropertyList: tags,
            format: .binary,
            options: 0
        )
        let result = data.withUnsafeBytes { buffer in
            setxattr(url.path, userTagsAttribute, buffer.baseAddress, data.count, 0, 0)
        }
        if result != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func cleanTagName(_ tag: String) -> String {
        tag.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? tag
    }

    private static func colorTagName(from tag: String) -> String? {
        let components = tag.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let colorCode = components.dropFirst().first,
           let colorName = colorCodeNames[colorCode] {
            return colorName
        }

        let cleanName = cleanTagName(tag)
        if MacColorTag.isColorTag(cleanName) {
            return cleanName
        }

        return localizedColorNames[cleanName]
    }
}
