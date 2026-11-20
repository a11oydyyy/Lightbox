import SwiftUI

/// Opened from the export status in the title: progress and Stop while the
/// export runs, then each file that did not export, with Photoshop's or the
/// file system's reason.
struct ExportStatusPopover: View {
    @ObservedObject var appState: AppState
    /// Progress publishes here rather than on `appState`.
    @ObservedObject private var activity: BackgroundActivityState
    var close: () -> Void

    init(appState: AppState, close: @escaping () -> Void) {
        self.appState = appState
        activity = appState.activity
        self.close = close
    }

    var body: some View {
        Group {
            if let progress = appState.titleExportProgress {
                content(progress)
            }
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
        .lightboxPopoverSurface()
        .tint(LightboxColorTokens.accent)
        .preferredColorScheme(appState.preferredColorScheme)
    }

    private func content(_ progress: FileTransferProgress) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(appState.exportStatusText(progress))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(progress.phase == .failed ? Color.red : Color.primary)

            if progress.phase == .active {
                if !progress.currentName.isEmpty {
                    Text(progress.currentName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                ProgressView(value: progress.fractionCompleted)
                    .progressViewStyle(.linear)
            }

            if !progress.failures.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(progress.failures.enumerated()), id: \.offset) { _, failure in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(failure.sourceURL.lastPathComponent)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(failure.message)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 180)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                if progress.phase == .active {
                    Button(appState.exportText.stop) { appState.cancelFileTransfer() }
                } else {
                    Button(appState.exportText.done) {
                        appState.dismissFileTransferStatus()
                        close()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .font(.system(size: 11, weight: .semibold))
        }
    }
}
