import Foundation

struct LightboxSearchStatus: Equatable, Sendable {
    var isSearching: Bool
    var limitReached = false
}

struct LightboxSearchScanResult: Sendable {
    var assets: [LightboxAsset]
    var folders: [LibraryFolderEntry] = []
    var visitedCount: Int
    var limitReached: Bool
}

struct LightboxSearchQuery: Equatable, Sendable {
    private var nameTerms: [String] = []

    var isEmpty: Bool {
        nameTerms.isEmpty
    }

    static func parse(_ rawValue: String) -> LightboxSearchQuery {
        let terms = rawValue
            .split(whereSeparator: \.isWhitespace)
            .map { normalized(String($0)) }
            .filter { !$0.isEmpty }
        return LightboxSearchQuery(nameTerms: terms)
    }

    func matches(_ asset: LightboxAsset) -> Bool {
        mayMatchAssetName(asset.originalName)
    }

    func mayMatchAssetName(_ name: String) -> Bool {
        containsAllTerms(in: name)
    }

    func mayMatchFolderName(_ name: String) -> Bool {
        containsAllTerms(in: name)
    }

    func matches(_ folder: LibraryFolderEntry) -> Bool {
        mayMatchFolderName(folder.name)
    }

    private func containsAllTerms(in value: String) -> Bool {
        let searchableValue = Self.normalized(value)
        for term in nameTerms where !searchableValue.contains(term) {
            return false
        }
        return true
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}
