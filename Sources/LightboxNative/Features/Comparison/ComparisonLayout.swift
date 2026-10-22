import CoreGraphics

/// Sizes the images of a comparison so they read as one set: every image
/// shares one height, so tops, bottoms and captions line up, in rows that
/// keep the numbered order. Tries one to three rows and keeps whichever
/// shows the images largest (four images usually land as two by two). When
/// there are so many that every image would be tiny, a single row keeps a
/// readable height and scrolls sideways.
struct ComparisonLayout: Equatable {
    /// Indices into the compared images, row by row.
    var rows: [[Int]]
    var imageSizes: [CGSize]
    var scrolls: Bool

    static let spacing: CGFloat = 20
    /// Gap above the caption plus its two lines.
    static let captionHeight: CGFloat = 46
    static let maximumRows = 3
    /// Below this image height the set scrolls in one row instead.
    static let minimumImageHeight: CGFloat = 150
    /// Share of the available height a scrolling row uses.
    static let scrollingHeightShare: CGFloat = 0.6

    static func make(aspectRatios: [CGFloat], available: CGSize) -> ComparisonLayout {
        let count = aspectRatios.count
        guard count > 0, available.width > 0, available.height > captionHeight else {
            return ComparisonLayout(rows: [Array(0..<count)], imageSizes: aspectRatios.map { _ in .zero }, scrolls: false)
        }
        var best: (rows: [[Int]], height: CGFloat, area: CGFloat)?
        for rowCount in 1...min(count, maximumRows) {
            let rows = split(count: count, into: rowCount)
            let heightLimit = (available.height - spacing * CGFloat(rowCount - 1)) / CGFloat(rowCount) - captionHeight
            let widthLimit = rows.map { row in
                (available.width - spacing * CGFloat(row.count - 1)) / row.reduce(0) { $0 + aspectRatios[$1] }
            }.min() ?? 0
            let height = min(heightLimit, widthLimit)
            let area = aspectRatios.reduce(0) { $0 + $1 * height * height }
            if height > 0, area > best?.area ?? 0 { best = (rows, height, area) }
        }
        if let best, best.height >= minimumImageHeight || count <= 2 {
            return ComparisonLayout(rows: best.rows, imageSizes: sizes(aspectRatios, height: best.height), scrolls: false)
        }
        let height = (available.height - captionHeight) * scrollingHeightShare
        return ComparisonLayout(rows: [Array(0..<count)], imageSizes: sizes(aspectRatios, height: height), scrolls: true)
    }

    /// Consecutive rows, as even as possible, with any extra image in the
    /// first rows.
    private static func split(count: Int, into rowCount: Int) -> [[Int]] {
        var rows: [[Int]] = []
        var start = 0
        for row in 0..<rowCount {
            let length = count / rowCount + (row < count % rowCount ? 1 : 0)
            rows.append(Array(start..<start + length))
            start += length
        }
        return rows
    }

    private static func sizes(_ aspectRatios: [CGFloat], height: CGFloat) -> [CGSize] {
        aspectRatios.map { CGSize(width: ($0 * height).rounded(), height: height.rounded()) }
    }
}
