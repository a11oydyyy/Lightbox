import SwiftUI

struct ImportProgressPill: View {
    var progress: ImportProgress

    var body: some View {
        HStack(spacing: 10) {
            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
                .frame(width: 72)

            Text("\(progress.processed)/\(progress.total)")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .lightboxGlass(Capsule(), interactive: true)
    }
}
