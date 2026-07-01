import AppKit
import SwiftUI

struct ComparisonOverlay: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var assets: [LightboxAsset]

    private static let coordinateSpaceName = "ComparisonOverlaySpace"

    @State private var isPresented = false
    @State private var isClosing = false
    @State private var paneFrames: [CGRect] = []
    @State private var escapeMonitor: Any?

    var body: some View {
        GeometryReader { proxy in
            let isCompact = proxy.size.width < 960
            let usesBoardLayout = assets.count > 2
            let contentPadding = EdgeInsets(
                top: isCompact ? 56 : 72,
                leading: isCompact ? 26 : 58,
                bottom: isCompact ? 42 : 58,
                trailing: isCompact ? 26 : 58
            )

            ZStack {
                ComparisonBackground(colorScheme: colorScheme)
                    .opacity(isPresented ? 1 : 0)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        closeAnimated()
                    }

                comparisonContent(isCompact: isCompact, viewport: proxy.size)
                    .padding(contentPadding)
                    .opacity(isPresented ? 1 : 0)
                    .scaleEffect(isPresented ? 1 : (usesBoardLayout ? 0.992 : 0.985))

                ComparisonBlankClickLayer(
                    protectedFrames: paneFrames,
                    onBlankClick: closeAnimated
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .zIndex(10)
            }
            .coordinateSpace(name: Self.coordinateSpaceName)
            .contentShape(Rectangle())
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { value in
                        closeIfBlank(at: value.location)
                    }
            )
            .onPreferenceChange(ComparisonPaneFramePreferenceKey.self) { frames in
                paneFrames = frames
            }
        }
        .transition(.opacity)
        .onAppear {
            installEscapeMonitor()

            guard !reduceMotion else {
                isPresented = true
                return
            }

            withAnimation(MotionTokens.preview) {
                isPresented = true
            }
        }
        .onDisappear {
            removeEscapeMonitor()
        }
    }

    @ViewBuilder
    private func comparisonContent(isCompact: Bool, viewport: CGSize) -> some View {
        if assets.count > 2 {
            comparisonBoard(viewport: viewport, isCompact: isCompact)
        } else if isCompact {
            VStack(spacing: 18) {
                comparisonPanes(quality: .comparison)
            }
        } else {
            HStack(spacing: 18) {
                comparisonPanes(quality: .comparison)
            }
        }
    }

    private func comparisonPanes(quality: ImageCacheQuality) -> some View {
        ForEach(Array(assets.enumerated()), id: \.element.id) { index, asset in
            ComparisonPane(label: comparisonLabel(for: index), asset: asset, imageQuality: quality)
                .recordsComparisonPaneFrame(in: Self.coordinateSpaceName)
        }
    }

    private func comparisonBoard(viewport: CGSize, isCompact: Bool) -> some View {
        let visibleColumns = CGFloat(isCompact ? 2 : min(4, max(3, assets.count)))
        let outerPadding = isCompact ? 52.0 : 116.0
        let totalSpacing = (visibleColumns - 1) * 16
        let paneWidth = max(220, floor((viewport.width - outerPadding - totalSpacing) / visibleColumns))

        return ScrollView(.horizontal) {
            LazyHStack(spacing: 16) {
                ForEach(Array(assets.enumerated()), id: \.element.id) { index, asset in
                    ComparisonPane(label: comparisonLabel(for: index), asset: asset, imageQuality: .comparison)
                        .frame(width: paneWidth)
                        .recordsComparisonPaneFrame(in: Self.coordinateSpaceName)
                }
            }
            .padding(.horizontal, 1)
        }
        .scrollIndicators(.hidden)
    }

    private func comparisonLabel(for index: Int) -> String {
        "\(index + 1)"
    }

    private func closeIfBlank(at point: CGPoint) {
        let protectedFrames = paneFrames.map { $0.insetBy(dx: -8, dy: -8) }
        guard !protectedFrames.contains(where: { $0.contains(point) }) else { return }
        closeAnimated()
    }

    private func closeAnimated() {
        guard !isClosing else { return }
        isClosing = true
        let delay: Duration = reduceMotion ? .milliseconds(40) : .milliseconds(180)

        withAnimation(MotionTokens.ifAllowed(MotionTokens.preview, reduceMotion: reduceMotion)) {
            isPresented = false
        }

        Task { @MainActor in
            try? await Task.sleep(for: delay)
            appState.closeComparison()
        }
    }

    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            closeAnimated()
            return nil
        }
    }

    private func removeEscapeMonitor() {
        guard let escapeMonitor else { return }
        NSEvent.removeMonitor(escapeMonitor)
        self.escapeMonitor = nil
    }
}

private struct ComparisonBlankClickLayer: NSViewRepresentable {
    var protectedFrames: [CGRect]
    var onBlankClick: () -> Void

    func makeNSView(context: Context) -> ComparisonBlankClickView {
        ComparisonBlankClickView()
    }

    func updateNSView(_ nsView: ComparisonBlankClickView, context: Context) {
        nsView.protectedFrames = protectedFrames.map { $0.insetBy(dx: -8, dy: -8) }
        nsView.onBlankClick = onBlankClick
    }
}

private final class ComparisonBlankClickView: NSView {
    var protectedFrames: [CGRect] = []
    var onBlankClick: () -> Void = {}

    override var isFlipped: Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !protectedFrames.isEmpty else {
            return nil
        }

        guard !protectedFrames.contains(where: { $0.contains(point) }) else {
            return nil
        }

        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        onBlankClick()
    }
}

private struct ComparisonPaneFramePreferenceKey: PreferenceKey {
    static let defaultValue: [CGRect] = []

    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

private extension View {
    func recordsComparisonPaneFrame(in coordinateSpaceName: String) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ComparisonPaneFramePreferenceKey.self,
                    value: [proxy.frame(in: .named(coordinateSpaceName))]
                )
            }
        }
    }
}

private struct ComparisonPane: View {
    var label: String
    var asset: LightboxAsset
    var imageQuality: ImageCacheQuality

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topLeading) {
                AssetImageView(asset: asset, contentMode: .fit, quality: imageQuality)
                    .imageDecodePriority(.high)
                    .clipShape(RoundedRectangle(cornerRadius: RadiusTokens.card, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: RadiusTokens.card, style: .continuous)
                            .stroke(.white.opacity(0.20), lineWidth: 0.8)
                    }
                    .shadow(color: .black.opacity(0.16), radius: 14, y: 8)

                Text(label)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.primary.opacity(0.86))
                    .frame(width: 24, height: 24)
                    .background(.ultraThinMaterial.opacity(0.76), in: Circle())
                    .overlay {
                        Circle()
                            .stroke(.white.opacity(0.22), lineWidth: 0.7)
                    }
                    .padding(10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())

            VStack(spacing: 3) {
                Text(asset.originalName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(dimensions)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.90))
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var dimensions: String {
        "\(Int(asset.width.rounded())) x \(Int(asset.height.rounded()))"
    }
}

private struct ComparisonBackground: View {
    var colorScheme: ColorScheme

    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .overlay {
                LinearGradient(
                    colors: [
                        Color.white.opacity(colorScheme == .dark ? 0.04 : 0.34),
                        Color.black.opacity(colorScheme == .dark ? 0.18 : 0.035)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
    }
}
