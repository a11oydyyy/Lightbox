import Foundation
import Testing
@testable import LightboxNative

@Test func refreshDimensionsRequireMatchingKnownFileVersionAndValidSize() {
    let url = URL(fileURLWithPath: "/tmp/refresh.jpg")
    let old = LightboxAsset(originalName: "refresh.jpg", width: 40, height: 60,
        tags: ["Red"], sourceURL: url, addedAt: .distantPast,
        contentModifiedAt: Date(timeIntervalSince1970: 100), fileSize: 3, palette: MockPalette.imported[0])
    var scan = old
    scan.width = 1; scan.height = 1; scan.metadataLoaded = false; scan.tags = ["Blue"]
    let snapshot = SearchMetadataSnapshot([old])
    let merged = snapshot.mergingDimensions(into: [scan])[0]
    #expect(merged.width == 40 && merged.height == 60 && merged.metadataLoaded)
    #expect(merged.tags == ["Blue"] && merged.originalName == scan.originalName)
    for invalidation in 0..<5 {
        var changed = scan
        switch invalidation {
        case 0: changed.fileSize = 4
        case 1: changed.contentModifiedAt = Date(timeIntervalSince1970: 101)
        case 2: changed.contentModifiedAt = nil
        case 3: changed.fileSize = nil
        default: changed.sourceURL = URL(fileURLWithPath: "/tmp/moved.jpg")
        }
        #expect(snapshot.mergingDimensions(into: [changed]) == [changed])
    }
    for invalidation in 0..<4 {
        var invalid = old
        switch invalidation {
        case 0: invalid.width = 0
        case 1: invalid.height = .infinity
        case 2: invalid.metadataLoaded = false
        default: invalid.fileSize = nil
        }
        #expect(SearchMetadataSnapshot([invalid]).mergingDimensions(into: [scan]) == [scan])
    }
}
