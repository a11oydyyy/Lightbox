import AppKit
import SwiftUI

struct ComparisonOverlay: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var assets: [LightboxAsset]

    private static let coordinateSpaceName = "ComparisonOverlaySpace"

    @LightboxViewState private var isPresented = false
    @LightboxViewState private var isClosing = false
    @LightboxViewState private var paneFrames: [CGRect] = []
    @LightboxViewState private var escapeMonitor: Any?

    var body: some View {
        GeometryReader { proxy in
            let isCompact = proxy.size.width < 960
            let usesBoardLayout = assets.count > 2
            // Clears the close button above and matches the preview's margins.
            let contentPadding = EdgeInsets(
                top: isCompact ? 64 : 76,
                leading: isCompact ? 26 : 58,
                bottom: isCompact ? 36 : 48,
                trailing: isCompact ? 26 : 58
            )
            let available = CGSize(
                width: proxy.size.width - contentPadding.leading - contentPadding.trailing,
                height: proxy.size.height - contentPadding.top - contentPadding.bottom
            )

            ZStack {
                ComparisonBackground()
                    .opacity(isPresented ? 1 : 0)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        closeAnimated()
                    }

                comparisonContent(available: available, horizontalInset: contentPadding.leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .overlay(alignment: .topTrailing) {
                Button(action: closeAnimated) {
                    Image(systemName: "xmark")
                        .font(.system(size: LightboxControlMetrics.iconSize, weight: .medium))
                        .foregroundStyle(LightboxColorTokens.secondaryText)
                        .frame(width: LightboxControlMetrics.iconButtonSize, height: LightboxControlMetrics.iconButtonSize)
                }
                .buttonStyle(LightboxButtonHoverStyle(shape: RoundedRectangle(cornerRadius: LightboxControlMetrics.cornerRadius)))
                .help(appState.localized(.close))
                .accessibilityLabel(appState.localized(.close))
                .padding(.top, 58)
                .padding(.trailing, 22)
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

            withAnimation(MotionTokens.ifAllowed(MotionTokens.preview, reduceMotion: reduceMotion)) {
                isPresented = true
            }
        }
        .onDisappear {
            removeEscapeMonitor()
        }
    }

    @ViewBuilder
    private func comparisonContent(available: CGSize, horizontalInset: CGFloat) -> some View {
        let layout = ComparisonLayout.make(aspectRatios: assets.map(\.aspectRatio), available: available)
        if layout.scrolls {
            // Scrolls edge to edge; the inset only pads the first and last image.
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: ComparisonLayout.spacing) {
                    ForEach(layout.rows.first ?? [], id: \.self) { pane($0, layout) }
                }
                .padding(.horizontal, horizontalInset)
            }
            .scrollIndicators(.hidden)
            .padding(.horizontal, -horizontalInset)
        } else {
            VStack(spacing: ComparisonLayout.spacing) {
                ForEach(layout.rows, id: \.self) { row in
                    HStack(alignment: .top, spacing: ComparisonLayout.spacing) {
                        ForEach(row, id: \.self) { pane($0, layout) }
                    }
                }
            }
        }
    }

    private func pane(_ index: Int, _ layout: ComparisonLayout) -> some View {
        ComparisonPane(
            label: comparisonLabel(for: index),
            asset: assets[index],
            imageSize: index < layout.imageSizes.count ? layout.imageSizes[index] : .zero
        )
        .id(assets[index].id)
        .recordsComparisonPaneFrame(in: Self.coordinateSpaceName)
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
        let ownerWindow = NSApp.keyWindow
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak ownerWindow] event in
            guard let ownerWindow, event.window === ownerWindow, event.keyCode == 53,
                  event.window?.isKeyWindow == true,
                  !(event.window?.firstResponder is NSTextView),
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            else { return event }
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

/// One compared image at its layout size, with its number on the image and
/// its name and file summary directly below.
private struct ComparisonPane: View {
    var label: String
    var asset: LightboxAsset
    var imageSize: CGSize

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: RadiusTokens.card, style: .continuous)
    }

    var body: some View {
        VStack(spacing: 10) {
            AssetImageView(asset: asset, contentMode: .fill, quality: .comparison)
                .imageDecodePriority(.high)
                .frame(width: imageSize.width, height: imageSize.height)
                .clipShape(shape)
                .overlay { shape.strokeBorder(LightboxColorTokens.border.opacity(0.55), lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.14), radius: 12, y: 6)
                .overlay(alignment: .topLeading) {
                    Text(label)
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(.black.opacity(0.42), in: Circle())
                        .overlay { Circle().strokeBorder(.white.opacity(0.28), lineWidth: 0.5) }
                        .padding(8)
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(label). \(asset.originalName)")

            VStack(spacing: 3) {
                Text(asset.originalName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LightboxColorTokens.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(asset.fileSummaryText)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(LightboxColorTokens.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // Narrow images borrow the gap beside them for a readable caption.
            .frame(width: imageSize.width + ComparisonLayout.spacing - 4)
        }
        .frame(width: imageSize.width)
    }
}

private struct ComparisonBackground: View {
    var body: some View {
        LightboxColorTokens.inspection
    }
}
