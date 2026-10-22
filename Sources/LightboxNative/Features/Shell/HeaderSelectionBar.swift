import AppKit
import SwiftUI

/// Multi-selection summary shown in the header's center slot, where the folder
/// title sits otherwise: count, Finder tags for the selection, Compare and Clear.
struct HeaderSelectionBar: View {
    @EnvironmentObject private var appState: AppState
    /// `AppState` republishes only when a multi-selection starts or ends;
    /// the count and tag coverage follow the selection itself.
    @ObservedObject var selection: GallerySelectionState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            Text(appState.selectedCountText(appState.selectedAssetCount))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LightboxColorTokens.primaryText)
                .monospacedDigit()
                .lightboxNumericTextTransition(value: Double(appState.selectedAssetCount))
                .animation(MotionTokens.ifAllowed(MotionTokens.quick, reduceMotion: reduceMotion), value: appState.selectedAssetCount)

            divider

            HStack(spacing: MacTagDotMetrics.selectionSpacing) {
                ForEach(MacColorTag.all) { tag in
                    SelectionTagButton(tag: tag, coverage: appState.selectedAssetTagCoverage(for: tag.name)) {
                        withAnimation(MotionTokens.ifAllowed(MotionTokens.quick, reduceMotion: reduceMotion)) {
                            appState.toggleTagForSelection(tag.name)
                        }
                    }
                }
            }
            .frame(height: MacTagDotMetrics.selectionHeight)

            divider

            HStack(spacing: 2) {
                actionButton(appState.localized(.compare)) { appState.showComparisonFromSelection() }
                    .disabled(!appState.canCompareSelection)
                actionButton(appState.localized(.clear)) { appState.clearSelection() }
            }
        }
        .fixedSize()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var divider: some View {
        Capsule()
            .fill(LightboxColorTokens.border)
            .frame(width: 1, height: 16)
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LightboxColorTokens.secondaryText)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .contentShape(Capsule())
        }
        .buttonStyle(LightboxButtonHoverStyle(shape: Capsule()))
    }
}

private struct SelectionTagButton: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var tag: MacColorTag
    var coverage: Double
    var action: () -> Void

    private var isFullyApplied: Bool { coverage >= 0.999 }
    private var isPartiallyApplied: Bool { coverage > 0 && !isFullyApplied }

    var body: some View {
        Button(action: action) {
            ZStack {
                if isFullyApplied || isPartiallyApplied {
                    Circle()
                        .fill(tag.color.opacity(isFullyApplied ? 0.18 : 0.10))
                        .frame(width: MacTagDotMetrics.selectionHitWidth, height: MacTagDotMetrics.selectionHitWidth)
                }

                Circle()
                    .fill(tag.color.opacity(isFullyApplied ? 1 : 0.84))
                    .frame(width: MacTagDotMetrics.selectionDotDiameter, height: MacTagDotMetrics.selectionDotDiameter)
                    .overlay {
                        Circle().stroke(.white.opacity(0.58), lineWidth: 0.7)
                    }

                if isFullyApplied {
                    Circle()
                        .stroke(tag.color.opacity(0.72), lineWidth: 1.4)
                        .frame(width: MacTagDotMetrics.selectionRingDiameter, height: MacTagDotMetrics.selectionRingDiameter)
                } else if isPartiallyApplied {
                    Circle()
                        .stroke(tag.color.opacity(0.55), style: StrokeStyle(lineWidth: 1.2, dash: [2, 2]))
                        .frame(width: MacTagDotMetrics.selectionRingDiameter, height: MacTagDotMetrics.selectionRingDiameter)
                }
            }
            .frame(width: MacTagDotMetrics.selectionHitWidth, height: MacTagDotMetrics.selectionHeight)
            .contentShape(Circle())
        }
        .buttonStyle(LightboxButtonHoverStyle(shape: Circle()))
        .help(appState.localizedColorTagName(tag.name))
        .accessibilityLabel(appState.localizedColorTagName(tag.name))
        .accessibilityValue("\(Int((coverage * 100).rounded()))%")
        .animation(MotionTokens.ifAllowed(MotionTokens.quick, reduceMotion: reduceMotion), value: coverage)
    }
}
