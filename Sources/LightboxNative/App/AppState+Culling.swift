import AppKit
import Foundation
import SwiftUI

/// A culling decision, stored as a Finder color tag so other apps see it.
enum CullMark: Hashable, Sendable {
    case keep
    case reject
    /// Neither: removes both tags.
    case clear

    static let keepTag = "Green"
    static let rejectTag = "Red"

    var tag: String? {
        switch self {
        case .keep: Self.keepTag
        case .reject: Self.rejectTag
        case .clear: nil
        }
    }

    /// The key in the preview and beside the Image menu item, as Lightroom's.
    var keyEquivalent: KeyEquivalent {
        switch self {
        case .keep: "p"
        case .reject: "x"
        case .clear: "u"
        }
    }

    /// The tags after marking: keep and reject replace each other; other
    /// colors stay.
    func applied(to tags: [String]) -> [String] {
        var next = tags.filter { $0 != Self.keepTag && $0 != Self.rejectTag }
        if let tag { next.append(tag) }
        return MacColorTag.sort(next)
    }
}

/// What the preview just marked, shown briefly over the image.
struct CullFeedback: Equatable {
    var id = UUID()
    var mark: CullMark
}

/// One undoable tag change. Registered when the change starts (so it lands
/// on the right undo or redo stack), given the old tags when the write is done.
@MainActor
final class TagUndoStep {
    fileprivate weak var undoManager: UndoManager?
    fileprivate var assets: [LightboxAsset] = []
    fileprivate var previousTags: [LightboxAsset.ID: [String]] = [:]

    func finish(assets: [LightboxAsset], previousTags: [LightboxAsset.ID: [String]]) {
        self.assets = assets.filter { previousTags[$0.id] != nil }
        self.previousTags = previousTags
        if self.assets.isEmpty { undoManager?.removeAllActions(withTarget: self) }
    }
}

// Culling in the preview: P keeps, X rejects, U clears. Keep and reject move
// on to the next image (not past the last); every mark is one undo step.
extension AppState {
    func markPreviewAsset(_ mark: CullMark) {
        guard previewPhase == .opening || previewPhase == .open,
              let asset = previewAsset, asset.isImage, asset.sourceURL != nil, !asset.isDeleted
        else { return }
        enqueueTagMutation(TagMutationRequest(
            tag: mark.tag ?? CullMark.keepTag, assets: [asset], action: .cull(mark),
            undoStep: registerTagUndo(actionName: CullText(appLanguage).actionName(mark))
        ))
        cullFeedback = CullFeedback(mark: mark)
        guard mark != .clear else { return }
        let images = activeAssets.filter(\.isImage)
        if let index = images.firstIndex(where: { $0.id == asset.id }), index < images.count - 1 {
            stepPreview(.next)
        }
    }

    /// Whether the preview's P, X, U and Z apply: an image file in the
    /// preview, with the keys going to it rather than to a text field.
    var canUsePreviewKeys: Bool {
        guard previewKeysActive, previewPhase == .opening || previewPhase == .open,
              let asset = previewAsset else { return false }
        return asset.isImage && asset.sourceURL != nil && !asset.isDeleted
    }

    func requestPreviewZoom() {
        guard canUsePreviewKeys else { return }
        previewZoomRequest &+= 1
    }

    func registerTagUndo(actionName: String) -> TagUndoStep? {
        guard let undoManager = renameUndoManager() else { return nil }
        let step = TagUndoStep()
        step.undoManager = undoManager
        // The undo manager does not retain its targets; the handler holds the step.
        undoManager.registerUndo(withTarget: step) { [weak self, step] _ in
            guard let self, !step.assets.isEmpty else { return }
            self.enqueueTagMutation(TagMutationRequest(
                tag: CullMark.keepTag, assets: step.assets, action: .restore(step.previousTags),
                undoStep: self.registerTagUndo(actionName: actionName)
            ))
        }
        undoManager.setActionName(actionName)
        return step
    }
}
