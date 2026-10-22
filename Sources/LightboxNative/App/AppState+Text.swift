import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// Localized titles and status text for the interface.
extension AppState {
    var preferredColorScheme: ColorScheme? {
        colorMode.preferredColorScheme
    }

    func localized(_ key: LightboxTextKey) -> String {
        LightboxLocalization.text(key, language: appLanguage)
    }

    func localizedColorTagName(_ tagName: String) -> String {
        LightboxLocalization.colorTagName(tagName, language: appLanguage)
    }

    func localizedColorTagFilterTitle(_ tagName: String) -> String {
        LightboxLocalization.filterColorTag(tagName, language: appLanguage)
    }

    func folderImageCountText(_ count: Int) -> String {
        LightboxLocalization.folderImageCount(count, language: appLanguage)
    }

    func selectedCountText(_ count: Int) -> String {
        LightboxLocalization.selectedCount(count, language: appLanguage)
    }

    func loadingStatusText(_ status: LibraryLoadingStatus) -> String {
        switch status.phase {
        case .scanning:
            return localized(.scanningFolder)
        case .preparingPreviews:
            return LightboxLocalization.preparingPreviews(status.processed, total: status.total, language: appLanguage)
        }
    }

    func sortFieldTitle(_ field: GallerySortField) -> String {
        switch field {
        case .time:
            localized(.sortTime)
        case .size:
            localized(.sortSize)
        case .tag:
            localized(.sortTag)
        case .fileName:
            localized(.sortFileName)
        case .type:
            localized(.sortType)
        case .dimensions:
            localized(.sortDimensions)
        }
    }

    var sortDirectionTitle: String {
        switch sortDirection {
        case .ascending:
            localized(.sortAscending)
        case .descending:
            localized(.sortDescending)
        }
    }

    var sortDirectionIcon: String {
        switch sortDirection {
        case .ascending:
            "arrow.up"
        case .descending:
            "arrow.down"
        }
    }
}
