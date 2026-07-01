import SwiftUI

struct AspectRatioKey: LayoutValueKey {
    static let defaultValue: CGFloat = 1
}

extension View {
    func masonryAspectRatio(_ ratio: CGFloat) -> some View {
        layoutValue(key: AspectRatioKey.self, value: ratio)
    }
}

struct MasonryLayout: Layout {
    var targetItemWidth: CGFloat
    var spacing: CGFloat

    var animatableData: CGFloat {
        get { targetItemWidth }
        set { targetItemWidth = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? targetItemWidth
        let metrics = layoutMetrics(totalWidth: width, subviews: subviews)
        return CGSize(width: width, height: metrics.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let metrics = layoutMetrics(totalWidth: bounds.width, subviews: subviews)
        var columnHeights = Array(repeating: CGFloat.zero, count: metrics.columns)

        for subview in subviews {
            let column = shortestColumnIndex(columnHeights)
            let x = bounds.minX + metrics.leadingInset + CGFloat(column) * (metrics.itemWidth + spacing)
            let y = bounds.minY + columnHeights[column]
            let height = itemHeight(for: subview, width: metrics.itemWidth)
            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: metrics.itemWidth, height: height)
            )
            columnHeights[column] += height + spacing
        }
    }

    private func layoutMetrics(totalWidth: CGFloat, subviews: Subviews) -> (columns: Int, itemWidth: CGFloat, leadingInset: CGFloat, height: CGFloat) {
        let columns = max(1, Int((totalWidth + spacing) / (targetItemWidth + spacing)))
        let maxItemWidth = floor((totalWidth - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        let itemWidth = min(targetItemWidth, maxItemWidth)
        let usedWidth = CGFloat(columns) * itemWidth + CGFloat(columns - 1) * spacing
        let leadingInset = max(0, floor((totalWidth - usedWidth) / 2))
        var columnHeights = Array(repeating: CGFloat.zero, count: columns)

        for subview in subviews {
            let column = shortestColumnIndex(columnHeights)
            columnHeights[column] += itemHeight(for: subview, width: itemWidth) + spacing
        }

        return (columns, itemWidth, leadingInset, max(0, (columnHeights.max() ?? 0) - spacing))
    }

    private func shortestColumnIndex(_ heights: [CGFloat]) -> Int {
        heights.enumerated().min { $0.element < $1.element }?.offset ?? 0
    }

    private func itemHeight(for subview: LayoutSubview, width: CGFloat) -> CGFloat {
        let aspectRatio = max(0.35, subview[AspectRatioKey.self])
        return width / aspectRatio
    }
}
