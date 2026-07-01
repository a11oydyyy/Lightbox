import SwiftUI

struct DropOverlay: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack {
            Color.black.opacity(0.07)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 30, weight: .medium))
                    .symbolRenderingMode(.hierarchical)

                Text(appState.localized(.dropImagesToImport))
                    .font(.system(size: 15, weight: .semibold))
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 19)
            .lightboxGlass(RoundedRectangle(cornerRadius: 18, style: .continuous), interactive: true)
        }
        .allowsHitTesting(false)
    }
}
