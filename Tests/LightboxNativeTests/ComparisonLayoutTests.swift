import CoreGraphics
import Testing
@testable import LightboxNative

private func fits(_ layout: ComparisonLayout, in available: CGSize) -> Bool {
    let spacing = ComparisonLayout.spacing
    let rowHeights = layout.rows.map { row in row.map { layout.imageSizes[$0].height }.max() ?? 0 }
    let height = rowHeights.reduce(0) { $0 + $1 + ComparisonLayout.captionHeight } + spacing * CGFloat(layout.rows.count - 1)
    let widths = layout.rows.map { row in row.reduce(0) { $0 + layout.imageSizes[$1].width } + spacing * CGFloat(row.count - 1) }
    return height <= available.height + 1 && (widths.max() ?? 0) <= available.width + 1
}

@Test func comparisonImagesShareOneHeightAndKeepTheirOrder() {
    let available = CGSize(width: 1160, height: 690)
    for ratios in [[1.5, 0.67], [1.33, 0.67, 1.78, 1.0], [1.5, 1.5, 1.5], [0.67, 0.67, 0.67, 0.67, 0.67]] as [[CGFloat]] {
        let layout = ComparisonLayout.make(aspectRatios: ratios, available: available)
        #expect(Set(layout.imageSizes.map(\.height)).count == 1, "\(ratios)")
        #expect(layout.rows.flatMap { $0 } == Array(ratios.indices), "\(ratios)")
        for (size, ratio) in zip(layout.imageSizes, ratios) {
            #expect(abs(size.width / size.height - ratio) < 0.02)
        }
        #expect(!layout.scrolls)
        #expect(fits(layout, in: available), "\(ratios): \(layout)")
    }
}

@Test func comparisonPicksTheArrangementThatShowsImagesLargest() {
    // Two landscape images in a tall window stack; side by side in a wide one.
    let tall = ComparisonLayout.make(aspectRatios: [1.5, 1.5], available: CGSize(width: 700, height: 900))
    #expect(tall.rows.count == 2)
    let wide = ComparisonLayout.make(aspectRatios: [1.5, 1.5], available: CGSize(width: 1600, height: 700))
    #expect(wide.rows.count == 1)
    // Four mixed images in a desktop window: two by two.
    let four = ComparisonLayout.make(aspectRatios: [1.33, 0.67, 1.78, 1.0], available: CGSize(width: 1160, height: 690))
    #expect(four.rows == [[0, 1], [2, 3]])
}

@Test func manyComparedImagesScrollInOneReadableRow() {
    let available = CGSize(width: 1160, height: 690)
    let layout = ComparisonLayout.make(aspectRatios: Array(repeating: 1.5, count: 14), available: available)
    #expect(layout.scrolls)
    #expect(layout.rows == [Array(0..<14)])
    #expect(layout.imageSizes[0].height >= ComparisonLayout.minimumImageHeight)
}
