import AppKit
import SwiftUI

struct MacColorTag: Identifiable, Hashable {
    var name: String
    var nsColor: NSColor

    var color: Color {
        Color(nsColor: nsColor)
    }

    var id: String {
        name
    }

    static let all: [MacColorTag] = [
        MacColorTag(name: "Red", nsColor: .systemRed),
        MacColorTag(name: "Orange", nsColor: .systemOrange),
        MacColorTag(name: "Yellow", nsColor: .systemYellow),
        MacColorTag(name: "Green", nsColor: .systemGreen),
        MacColorTag(name: "Blue", nsColor: .systemBlue),
        MacColorTag(name: "Purple", nsColor: .systemPurple),
        MacColorTag(name: "Gray", nsColor: .systemGray)
    ]

    static func isColorTag(_ tag: String) -> Bool {
        order[tag] != nil
    }

    static func sort(_ tags: [String]) -> [String] {
        tags.sorted { left, right in
            let leftOrder = order[left] ?? Int.max
            let rightOrder = order[right] ?? Int.max
            if leftOrder != rightOrder {
                return leftOrder < rightOrder
            }
            return left.localizedStandardCompare(right) == .orderedAscending
        }
    }

    private static let order: [String: Int] = Dictionary(
        uniqueKeysWithValues: all.enumerated().map { index, tag in
            (tag.name, index)
        }
    )
}

enum MacTagDotMetrics {
    static let menuDotDiameter: CGFloat = 16
    static let menuHitDiameter: CGFloat = 28
    static let menuHorizontalInset: CGFloat = 14
    static let menuHeight: CGFloat = 40
    static let menuStrokeWidth: CGFloat = 0.8

    static let assetOverlayDotDiameter: CGFloat = 8
    static let assetOverlaySpacing: CGFloat = 4
    static let assetOverlayStrokeWidth: CGFloat = 0.7

    static let previewInfoDotDiameter: CGFloat = 8
    static let previewInfoSpacing: CGFloat = 7
    static let previewInfoStrokeWidth: CGFloat = 0.55

    static let sidebarDotDiameter: CGFloat = 5
    static let sidebarSpacing: CGFloat = 2

    static let selectionHitWidth: CGFloat = 22
    static let selectionHeight: CGFloat = 26
    static let selectionDotDiameter: CGFloat = 10
    static let selectionRingDiameter: CGFloat = 20
    static let selectionSpacing: CGFloat = 3

    static var menuIntrinsicWidth: CGFloat {
        menuHorizontalInset * 2 + CGFloat(MacColorTag.all.count) * menuHitDiameter
    }

    static var selectionStripWidth: CGFloat {
        CGFloat(MacColorTag.all.count) * selectionHitWidth
            + CGFloat(max(0, MacColorTag.all.count - 1)) * selectionSpacing
    }
}
