import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// The image preview: opening, stepping, closing and its geometry.
extension AppState {
    var previewAsset: LightboxAsset? {
        guard let previewAssetID else { return nil }
        return assetForCurrentPresentation(previewAssetID)
            ?? (previewAssetSnapshot?.id == previewAssetID ? previewAssetSnapshot : nil)
    }

    var isPreviewPresented: Bool {
        previewPhase == .opening || previewPhase == .open || previewPhase == .closing
    }

    var isPreviewClosing: Bool {
        previewPhase == .closing
    }

    var isOverlayChromeVisible: Bool {
        // Return chrome with the gallery veil, independently of image landing.
        !isComparing && (previewAssetID == nil || isPreviewClosing)
    }

    var needsPreviewRootClickCatcher: Bool {
        isPreviewPresented && !previewInteractionLayerReady
    }

    var hasActiveOverlay: Bool {
        isPreviewPresented || isComparing
    }

    func updatePreviewSpaceAssetFrames(_ frames: [LightboxAsset.ID: CGRect]) {
        storedPreviewSpaceAssetFrames = frames
    }

    /// `cornerRadius` is the thumbnails' on screen: the preview opens from
    /// and closes into that shape.
    func setPreviewSpaceAssetFrameProvider(cornerRadius: CGFloat = RadiusTokens.card,
                                           _ provider: (() -> [LightboxAsset.ID: CGRect])?) {
        previewSpaceAssetFrameProvider = provider
        previewSourceCornerRadius = provider == nil ? RadiusTokens.card : cornerRadius
        if provider == nil { storedPreviewSpaceAssetFrames = [:] }
    }

    func previewSpaceFrame(for assetID: LightboxAsset.ID) -> CGRect? {
        previewSpaceAssetFrames[assetID]
    }

    private func previewSpaceAssetHit(at point: CGPoint?) -> (asset: LightboxAsset, frame: CGRect)? {
        guard let point else { return nil }
        let frames = previewSpaceAssetFrames
        for asset in activeAssets {
            guard let frame = frames[asset.id],
                  frame.contains(point)
            else {
                continue
            }

            return (asset, frame)
        }

        return nil
    }

    func previewSwitchTarget(
        at point: CGPoint?,
        excluding currentAssetID: LightboxAsset.ID
    ) -> (asset: LightboxAsset, frame: CGRect)? {
        guard let hit = previewSpaceAssetHit(at: point),
              hit.asset.id != currentAssetID
        else {
            return nil
        }

        return hit
    }

    func previewSpaceHitDescription(at point: CGPoint?) -> String {
        guard let point else { return "point=nil" }
        if let hit = previewSpaceAssetHit(at: point) {
            return "hit=\(hit.asset.originalName) frame=\(Self.frameDescription(hit.frame)) point=\(LightboxClickFormatter.pointDescription(point))"
        }

        let frames = previewSpaceAssetFrames
        guard let nearest = activeAssets.compactMap({ asset -> (LightboxAsset, CGRect, CGFloat)? in
            guard let frame = frames[asset.id] else { return nil }
            return (asset, frame, Self.distance(from: point, to: frame))
        }).min(by: { $0.2 < $1.2 }) else {
            return "hit=nil frames=0 point=\(LightboxClickFormatter.pointDescription(point))"
        }

        return "hit=nil nearest=\(nearest.0.originalName) distance=\(String(format: "%.1f", nearest.2)) frame=\(Self.frameDescription(nearest.1)) point=\(LightboxClickFormatter.pointDescription(point))"
    }

    func markPreviewInteractionLayerReady(_ isReady: Bool) {
        guard previewInteractionLayerReady != isReady else { return }
        previewInteractionLayerReady = isReady
        Self.previewLogger.info("preview interaction-layer ready=\(isReady, privacy: .public) phase=\(self.previewPhase.rawValue, privacy: .public) session=\(self.previewSessionID.uuidString, privacy: .public)")
    }

    func handlePreviewRootClick(_ click: LightboxClickContext) {
        handlePreviewRootClick(at: click.localTopLeftLocation)
    }

    func handlePreviewRootClick(at point: CGPoint?) {
        guard isPreviewPresented else {
            Self.previewLogger.info("preview root-click ignored phase=\(self.previewPhase.rawValue, privacy: .public)")
            return
        }

        let underlying = previewSpaceHitDescription(at: point)
        if previewPhase == .closing {
            if let currentID = previewAssetID,
               let hit = previewSwitchTarget(at: point, excluding: currentID) {
                Self.previewLogger.info("preview root-click action=switch-during-close target=\(hit.asset.originalName, privacy: .public) underlying=\(underlying, privacy: .public)")
                showPreview(for: hit.asset, sourceFrame: hit.frame)
                return
            }

            if let previewAssetID {
                Self.previewLogger.info("preview root-click action=reopen-current underlying=\(underlying, privacy: .public)")
                _ = reopenPreviewDuringClose(for: previewAssetID)
            }
            return
        }

        guard previewPhase == .opening || previewPhase == .open else {
            Self.previewLogger.info("preview root-click ignored phase=\(self.previewPhase.rawValue, privacy: .public) underlying=\(underlying, privacy: .public)")
            return
        }

        Self.previewLogger.info("preview root-click action=close phase=\(self.previewPhase.rawValue, privacy: .public) underlying=\(underlying, privacy: .public)")
        _ = beginInteractivePreviewClose(after: .milliseconds(60), revealSourceAfter: .milliseconds(0))
    }

    func markPreviewKeyboardFocusAcquired(sessionID: UUID) {
        guard sessionID == previewSessionID,
              previewPhase == .opening || previewPhase == .open else { return }
        previewKeyboardFocusSessionID = sessionID
    }

    func handlePreviewArrowDuringKeyboardHandoff(_ key: UInt16) -> Bool {
        guard previewKeyboardFocusSessionID != previewSessionID,
              previewAssetID != nil, !isComparing,
              previewPhase == .opening || previewPhase == .open else { return false }
        switch key {
        case 123: stepPreview(.previous)
        case 124: stepPreview(.next)
        default: return false
        }
        return true
    }

    func showPreview(for asset: LightboxAsset? = nil, sourceFrame: CGRect? = nil) {
        selectedGalleryFolderID = nil
        guard let target = asset ?? selectedAsset ?? activeAssets.first(where: \.isImage) else {
            Self.previewLogger.info("preview show ignored reason=no-target phase=\(self.previewPhase.rawValue, privacy: .public)")
            return
        }
        // Other files have no preview yet; they open in their own app.
        guard target.isImage else {
            openInDefaultApplication(target)
            return
        }

        pendingPreviewStepAssetID = nil
        resolvePreviewTarget(
            target,
            sourceFrame: sourceFrame,
            requiresActiveAsset: false
        ) { [weak self] resolvedTarget in
            self?.presentPreview(resolvedTarget, sourceFrame: sourceFrame)
        }
    }

    private func presentPreview(_ target: LightboxAsset, sourceFrame: CGRect?) {
        pendingPreviewStepAssetID = nil
        let previousPhase = previewPhase
        let nextSessionID = UUID()
        closeComparison()
        previewCloseTask?.cancel()
        previewSourceRevealTask?.cancel()
        previewInteractionLayerReady = false
        previewPhase = .opening
        previewSessionID = nextSessionID
        previewStepDirection = nil
        selectedAssetIDs = []
        selectionAnchorID = nil
        selectedAssetID = target.id
        previewSourceHiddenAssetID = nil
        previewSourceFrame = sourceFrame
        previewAssetID = target.id
        previewAssetSnapshot = target
        Self.previewLogger.info("preview show phase=\(previousPhase.rawValue, privacy: .public)->opening session=\(nextSessionID.uuidString, privacy: .public) asset=\(target.originalName, privacy: .public) frame=\(Self.frameDescription(sourceFrame), privacy: .public) folder=\(self.currentFolderURL.lastPathComponent, privacy: .public)")
        schedulePreviewOpenCompletion()
    }

    func resolvePreviewTarget(
        _ asset: LightboxAsset,
        sourceFrame: CGRect?,
        requiresActiveAsset: Bool,
        completion: @escaping @MainActor @Sendable (LightboxAsset) -> Void
    ) {
        cancelPreviewDimensionResolution()
        guard needsPreviewDimensionResolve(asset),
              let url = asset.sourceURL
        else {
            completion(asset)
            return
        }

        let dimensionProbe = previewDimensionProbe
        let indexDatabaseURL = indexDatabaseURL
        let requestID = UUID()
        let requestSourceID = selectedSourceID
        let requestFolderPath = currentFolderURL.standardizedFileURL.path
        let requestSessionID = previewSessionID
        let requestAssetID = asset.id
        previewDimensionRequestID = requestID
        previewDimensionTask = Task.detached(priority: .userInitiated) { [weak self] in
            let dimensions = autoreleasepool {
                dimensionProbe(url)
            }
            guard !Task.isCancelled else { return }

            let didResolve = await MainActor.run { () -> Bool in
                guard let self,
                      self.previewDimensionRequestID == requestID
                else {
                    return false
                }
                self.previewDimensionTask = nil
                self.previewDimensionRequestID = nil
                guard !Task.isCancelled,
                      self.selectedSourceID == requestSourceID,
                      self.currentFolderURL.standardizedFileURL.path == requestFolderPath,
                      self.previewSessionID == requestSessionID,
                      !requiresActiveAsset || self.activeAssets.contains(where: { $0.id == requestAssetID })
                else {
                    Self.previewLogger.info("preview dimensions ignored stale-context assetID=\(requestAssetID, privacy: .public)")
                    return false
                }
                let resolved = self.resolvedPreviewTarget(
                    asset,
                    sourceFrame: sourceFrame,
                    dimensions: dimensions
                )
                completion(resolved)
                return true
            }

            guard didResolve,
                  !Task.isCancelled,
                  let dimensions,
                  dimensions.width > 1,
                  dimensions.height > 1
            else {
                return
            }
            LightboxIndexStore(databaseURL: indexDatabaseURL).updateCachedDimensions(
                sourceID: requestSourceID,
                updates: [IndexedAssetDimensions(
                    url: url,
                    width: dimensions.width,
                    height: dimensions.height
                )]
            )
        }
    }

    func cancelPreviewDimensionResolution(clearPendingStep: Bool = false) {
        previewDimensionTask?.cancel()
        previewDimensionTask = nil
        previewDimensionRequestID = nil
        if clearPendingStep {
            pendingPreviewStepAssetID = nil
        }
    }

    private func resolvedPreviewTarget(
        _ asset: LightboxAsset,
        sourceFrame: CGRect?,
        dimensions: CGSize?
    ) -> LightboxAsset {
        if let dimensions,
           dimensions.width > 1,
           dimensions.height > 1 {
            var resolved = asset
            resolved.width = dimensions.width
            resolved.height = dimensions.height
            resolved.metadataLoaded = true

            if let index = assets.firstIndex(where: { $0.id == asset.id }) {
                var nextAssets = assets
                nextAssets[index].width = dimensions.width
                nextAssets[index].height = dimensions.height
                nextAssets[index].metadataLoaded = true
                assets = nextAssets
            }
            updatePresentedAssetDimensions(
                asset.id,
                width: dimensions.width,
                height: dimensions.height,
                metadataLoaded: true
            )

            Self.previewLogger.info("preview dimensions resolved asset=\(asset.originalName, privacy: .public) width=\(dimensions.width, format: .fixed(precision: 0)) height=\(dimensions.height, format: .fixed(precision: 0))")
            return resolved
        }

        guard let sourceFrame,
              sourceFrame.width > 1,
              sourceFrame.height > 1
        else {
            return asset
        }

        var fallback = asset
        fallback.width = sourceFrame.width
        fallback.height = sourceFrame.height
        fallback.metadataLoaded = false

        if let index = assets.firstIndex(where: { $0.id == asset.id }) {
            var nextAssets = assets
            nextAssets[index].width = sourceFrame.width
            nextAssets[index].height = sourceFrame.height
            nextAssets[index].metadataLoaded = false
            assets = nextAssets
        }
        updatePresentedAssetDimensions(
            asset.id,
            width: sourceFrame.width,
            height: sourceFrame.height,
            metadataLoaded: false
        )

        Self.previewLogger.info("preview dimensions fallback-to-card asset=\(asset.originalName, privacy: .public) width=\(sourceFrame.width, format: .fixed(precision: 0)) height=\(sourceFrame.height, format: .fixed(precision: 0))")
        return fallback
    }

    private func needsPreviewDimensionResolve(_ asset: LightboxAsset) -> Bool {
        !asset.metadataLoaded || asset.width <= 1 || asset.height <= 1
    }

    func hidePreviewSourceForCurrentPreview(_ assetID: LightboxAsset.ID) {
        guard previewAssetID == assetID,
              previewPhase == .opening || previewPhase == .open
        else {
            Self.previewLogger.info("preview source hide ignored phase=\(self.previewPhase.rawValue, privacy: .public) session=\(self.previewSessionID.uuidString, privacy: .public)")
            return
        }

        previewSourceHiddenAssetID = assetID
        Self.previewLogger.info("preview source hide session=\(self.previewSessionID.uuidString, privacy: .public)")
    }

    private func markPreviewOpen() {
        guard previewPhase == .opening else {
            Self.previewLogger.info("preview open ignored phase=\(self.previewPhase.rawValue, privacy: .public) session=\(self.previewSessionID.uuidString, privacy: .public)")
            return
        }
        Self.previewLogger.info("preview open phase=opening->open session=\(self.previewSessionID.uuidString, privacy: .public)")
        previewPhase = .open
    }

    func beginPreviewClose(
        after delay: Duration = MotionTokens.previewGeometryDuration,
        revealSourceAfter sourceRevealDelay: Duration = MotionTokens.previewSourceRevealDelay
    ) -> Bool {
        let previousPhase = previewPhase
        guard previewPhase == .opening || previewPhase == .open else {
            Self.previewLogger.info("preview close rejected phase=\(self.previewPhase.rawValue, privacy: .public) session=\(self.previewSessionID.uuidString, privacy: .public)")
            return false
        }
        previewOpenTask?.cancel()
        previewCloseTask?.cancel()
        previewSourceRevealTask?.cancel()
        cancelPreviewDimensionResolution(clearPendingStep: true)
        previewPhase = .closing
        previewStepDirection = nil
        Self.previewLogger.info("preview close begin phase=\(previousPhase.rawValue, privacy: .public)->closing session=\(self.previewSessionID.uuidString, privacy: .public) delay=\(Self.durationDescription(delay), privacy: .public) revealDelay=\(Self.durationDescription(sourceRevealDelay), privacy: .public) sourceHidden=\(self.previewSourceHiddenAssetID != nil, privacy: .public)")
        previewSourceRevealTask = Task { [weak self] in
            try? await Task.sleep(for: sourceRevealDelay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                Self.previewLogger.info("preview source reveal session=\(self?.previewSessionID.uuidString ?? "nil", privacy: .public)")
                self?.previewSourceHiddenAssetID = nil
            }
        }
        previewCloseTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.finishPreviewClose()
            }
        }
        return true
    }

    func beginInteractivePreviewClose(
        after delay: Duration = MotionTokens.previewGeometryDuration,
        revealSourceAfter sourceRevealDelay: Duration = MotionTokens.previewSourceRevealDelay
    ) -> Bool {
        guard previewPhase == .opening || previewPhase == .open else { return false }
        return beginPreviewClose(after: delay, revealSourceAfter: sourceRevealDelay)
    }

    func reopenPreviewDuringClose(for assetID: LightboxAsset.ID) -> Bool {
        guard previewPhase == .closing,
              previewAssetID == assetID
        else {
            Self.previewLogger.info("preview reopen rejected phase=\(self.previewPhase.rawValue, privacy: .public) assetID=\(assetID, privacy: .public) session=\(self.previewSessionID.uuidString, privacy: .public)")
            return false
        }

        previewOpenTask?.cancel()
        previewCloseTask?.cancel()
        previewSourceRevealTask?.cancel()
        previewPhase = .opening
        previewStepDirection = nil
        previewSourceHiddenAssetID = assetID
        selectedAssetID = assetID
        Self.previewLogger.info("preview reopen phase=closing->opening session=\(self.previewSessionID.uuidString, privacy: .public) assetID=\(assetID, privacy: .public)")
        schedulePreviewOpenCompletion()
        return true
    }

    func closePreview() {
        cancelPreviewDimensionResolution(clearPendingStep: true)
        previewOpenTask?.cancel()
        previewCloseTask?.cancel()
        previewSourceRevealTask?.cancel()
        finishPreviewClose(force: true)
    }

    func closeActiveOverlay() {
        if isComparing {
            closeComparison()
            return
        }

        _ = beginPreviewClose()
    }

    private func finishPreviewClose(force: Bool = false) {
        let previousPhase = previewPhase
        guard force || previewPhase == .closing else {
            Self.previewLogger.info("preview finish ignored force=\(force, privacy: .public) phase=\(self.previewPhase.rawValue, privacy: .public) session=\(self.previewSessionID.uuidString, privacy: .public)")
            return
        }
        let returnID = previewAssetID.flatMap { id in activeAssets.contains(where: { $0.id == id }) ? id : nil }
        previewSourceRevealTask?.cancel()
        pendingPreviewStepAssetID = nil
        previewAssetID = nil
        previewAssetSnapshot = nil
        previewSourceHiddenAssetID = nil
        previewInteractionLayerReady = false
        selectedAssetID = nil
        selectedAssetIDs = []
        selectionAnchorID = nil
        previewSourceFrame = nil
        previewPhase = .closed
        previewStepDirection = nil
        if previousPhase != .closed {
            // Returning from preview restores the responder without moving the
            // viewport. Explicit gallery arrow navigation requests its own scroll.
            galleryKeyboardFocusID = returnID ?? activeAssets.first?.id
            // The list shows focus as a selected row, so the image just viewed
            // stays selected, as in Finder.
            if galleryViewMode == .list, let returnID {
                replaceSelection(with: [returnID], primary: returnID, anchor: returnID)
            }
        }
        Self.previewLogger.info("preview close finish force=\(force, privacy: .public) phase=\(previousPhase.rawValue, privacy: .public)->closed session=\(self.previewSessionID.uuidString, privacy: .public)")
    }

    private func schedulePreviewOpenCompletion() {
        previewOpenTask?.cancel()
        previewOpenTask = Task { [weak self] in
            try? await Task.sleep(for: MotionTokens.previewGeometryDuration)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.markPreviewOpen()
            }
        }
    }

    func stepPreview(_ direction: PreviewDirection) {
        // Stepping moves between images; other files in the gallery are skipped.
        let visible = activeAssets.filter(\.isImage)
        guard visible.count > 1,
              previewPhase == .opening || previewPhase == .open
        else { return }
        let currentID = pendingPreviewStepAssetID ?? previewAssetID ?? selectedAssetID
        let currentIndex = currentID.flatMap { id in visible.firstIndex { $0.id == id } } ?? 0
        let nextIndex: Int
        switch direction {
        case .previous:
            nextIndex = (currentIndex - 1 + visible.count) % visible.count
        case .next:
            nextIndex = (currentIndex + 1) % visible.count
        }
        let nextAsset = visible[nextIndex]
        pendingPreviewStepAssetID = nextAsset.id
        resolvePreviewTarget(
            nextAsset,
            sourceFrame: nil,
            requiresActiveAsset: true
        ) { [weak self] nextAsset in
            self?.presentPreviewStep(nextAsset, direction: direction)
        }
    }

    func presentPreviewStep(_ nextAsset: LightboxAsset, direction: PreviewDirection) {
        guard pendingPreviewStepAssetID == nextAsset.id else { return }
        pendingPreviewStepAssetID = nil
        guard previewPhase == .opening || previewPhase == .open,
              activeAssets.contains(where: { $0.id == nextAsset.id })
        else {
            return
        }
        previewOpenTask?.cancel()
        previewSourceRevealTask?.cancel()
        if previewPhase == .opening {
            previewPhase = .open
        }
        selectedAssetID = nextAsset.id
        // Follow the step in the gallery underneath: closing the preview then
        // returns to this image's card, which takes the keyboard focus.
        galleryKeyboardFocusID = nextAsset.id
        galleryKeyboardScrollGeneration &+= 1
        previewSourceHiddenAssetID = nil
        previewSourceFrame = nil
        previewStepDirection = direction
        previewAssetID = nextAsset.id
        previewAssetSnapshot = nextAsset
        Self.previewLogger.info("preview step direction=\(direction.rawValue, privacy: .public) asset=\(nextAsset.originalName, privacy: .public) session=\(self.previewSessionID.uuidString, privacy: .public)")
    }

    func assetForCurrentPresentation(_ assetID: LightboxAsset.ID) -> LightboxAsset? {
        assets.first { $0.id == assetID }
            ?? searchResultAssets?.first { $0.id == assetID }
            ?? cachedActiveAssets.first { $0.id == assetID }
    }

    private func updatePresentedAssetDimensions(
        _ assetID: LightboxAsset.ID,
        width: CGFloat,
        height: CGFloat,
        metadataLoaded: Bool
    ) {
        if let index = searchResultAssets?.firstIndex(where: { $0.id == assetID }) {
            searchResultAssets?[index].width = width
            searchResultAssets?[index].height = height
            searchResultAssets?[index].metadataLoaded = metadataLoaded
        }

        if let index = cachedActiveAssets.firstIndex(where: { $0.id == assetID }) {
            cachedActiveAssets[index].width = width
            cachedActiveAssets[index].height = height
            cachedActiveAssets[index].metadataLoaded = metadataLoaded
        }

        if previewAssetSnapshot?.id == assetID {
            previewAssetSnapshot?.width = width
            previewAssetSnapshot?.height = height
            previewAssetSnapshot?.metadataLoaded = metadataLoaded
        }
    }

    nonisolated static func frameDescription(_ frame: CGRect?) -> String {
        guard let frame else { return "nil" }
        return String(format: "x=%.1f y=%.1f w=%.1f h=%.1f", frame.minX, frame.minY, frame.width, frame.height)
    }

    nonisolated static func clickDescription(_ click: LightboxClickContext?, sourceFrame: CGRect?) -> String {
        LightboxClickFormatter.describe(click, previewSpacePoint: click?.mappedTopLeftPoint(in: sourceFrame))
    }

    nonisolated private static func distance(from point: CGPoint, to frame: CGRect) -> CGFloat {
        let dx: CGFloat
        if point.x < frame.minX {
            dx = frame.minX - point.x
        } else if point.x > frame.maxX {
            dx = point.x - frame.maxX
        } else {
            dx = 0
        }

        let dy: CGFloat
        if point.y < frame.minY {
            dy = frame.minY - point.y
        } else if point.y > frame.maxY {
            dy = point.y - frame.maxY
        } else {
            dy = 0
        }

        return hypot(dx, dy)
    }

    nonisolated private static func durationDescription(_ duration: Duration) -> String {
        "\(duration)"
    }
}
