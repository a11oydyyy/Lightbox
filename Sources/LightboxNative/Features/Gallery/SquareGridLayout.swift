import SwiftUI

struct SquareGridLayout: Layout {
    var targetItemWidth: CGFloat
    var spacing: CGFloat

    var animatableData: CGFloat {
        get { targetItemWidth }
        set { targetItemWidth = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? targetItemWidth
        let metrics = layoutMetrics(totalWidth: width, itemCount: subviews.count)
        return CGSize(width: width, height: metrics.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let metrics = layoutMetrics(totalWidth: bounds.width, itemCount: subviews.count)

        for index in subviews.indices {
            let column = index % metrics.columns
            let row = index / metrics.columns
            let x = bounds.minX + metrics.leadingInset + CGFloat(column) * (metrics.itemWidth + spacing)
            let y = bounds.minY + CGFloat(row) * (metrics.itemWidth + spacing)
            subviews[index].place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: metrics.itemWidth, height: metrics.itemWidth)
            )
        }
    }

    private func layoutMetrics(totalWidth: CGFloat, itemCount: Int) -> (columns: Int, itemWidth: CGFloat, leadingInset: CGFloat, height: CGFloat) {
        let columns = max(1, Int((totalWidth + spacing) / (targetItemWidth + spacing)))
        let maxItemWidth = floor((totalWidth - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        let itemWidth = min(targetItemWidth, maxItemWidth)
        let usedWidth = CGFloat(columns) * itemWidth + CGFloat(columns - 1) * spacing
        let leadingInset = max(0, floor((totalWidth - usedWidth) / 2))
        let rows = itemCount == 0 ? 0 : Int(ceil(Double(itemCount) / Double(columns)))
        let height = rows == 0 ? 0 : CGFloat(rows) * itemWidth + CGFloat(rows - 1) * spacing
        return (columns, itemWidth, leadingInset, height)
    }
}
