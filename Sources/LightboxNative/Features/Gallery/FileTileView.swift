import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A non-image file in the gallery: its Finder icon, name and size on a
/// faint fill, in a square tile. Nothing is read from the file itself, so
/// these tiles cost no I/O on network volumes.
struct FileTileView: View {
    var asset: LightboxAsset

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let iconSize = min(FileTileMetrics.maxIconSize, max(FileTileMetrics.minIconSize, side * 0.42))
            VStack(spacing: 6) {
                Image(nsImage: FileTileIcons.icon(forName: asset.originalName))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: iconSize, height: iconSize)
                    .padding(.bottom, 2)
                Text(asset.originalName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LightboxColorTokens.primaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let fileSize = asset.fileSize {
                    Text(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(LightboxColorTokens.mutedText)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, FileTileMetrics.inset)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(LightboxColorTokens.primaryText.opacity(FileTileMetrics.fillOpacity))
    }
}

enum FileTileMetrics {
    static let minIconSize: CGFloat = 40
    static let maxIconSize: CGFloat = 128
    static let inset: CGFloat = 12
    /// The gallery folder tiles' resting fill.
    static let fillOpacity = Double(FolderGridPlacement.restFillOpacity)
}

/// Finder icons by file type, shared across tiles: one lookup per extension.
@MainActor
enum FileTileIcons {
    private static var byExtension: [String: NSImage] = [:]

    static func icon(forName name: String) -> NSImage {
        let pathExtension = (name as NSString).pathExtension.lowercased()
        if let icon = byExtension[pathExtension] { return icon }
        let type = pathExtension.isEmpty ? UTType.data : (UTType(filenameExtension: pathExtension) ?? .data)
        let icon = NSWorkspace.shared.icon(for: type)
        byExtension[pathExtension] = icon
        return icon
    }
}
