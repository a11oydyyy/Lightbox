import SwiftUI

struct PreviewControls: View {
    var asset: LightboxAsset

    private var colorTags: [MacColorTag] {
        MacColorTag.all.filter { asset.tags.contains($0.name) }
    }

    var body: some View {
        VStack(spacing: colorTags.isEmpty ? 3 : 6) {
            Text(asset.originalName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)

            Text(dimensionsText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if !colorTags.isEmpty {
                HStack(spacing: MacTagDotMetrics.previewInfoSpacing) {
                    ForEach(colorTags) { tag in
                        Circle()
                            .fill(tag.color.opacity(0.94))
                            .frame(
                                width: MacTagDotMetrics.previewInfoDotDiameter,
                                height: MacTagDotMetrics.previewInfoDotDiameter
                            )
                            .overlay {
                                Circle()
                                    .stroke(.white.opacity(0.48), lineWidth: MacTagDotMetrics.previewInfoStrokeWidth)
                            }
                            .accessibilityLabel(tag.name)
                    }
                }
                .padding(.top, 1)
            }
        }
        .frame(minWidth: 188, maxWidth: 560, alignment: .center)
        .padding(.horizontal, 22)
        .padding(.vertical, 2)
        .shadow(color: Color(nsColor: .windowBackgroundColor).opacity(0.72), radius: 5, y: 1)
    }

    private var dimensionsText: String {
        "\(formattedDimension(asset.width)) x \(formattedDimension(asset.height))"
    }

    private func formattedDimension(_ value: CGFloat) -> String {
        Int(value).formatted(.number.grouping(.automatic))
    }
}
