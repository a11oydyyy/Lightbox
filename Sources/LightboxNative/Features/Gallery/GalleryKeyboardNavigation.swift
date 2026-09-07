import Foundation

/// Prefer spatial neighbors in masonry; offscreen entries fall back to reading order.
enum GalleryKeyboardNavigation {
    static func targetIndex(key: UInt16, current: Int, ids: [String], frames: [String: CGRect]) -> Int? {
        guard ids.indices.contains(current), [123, 124, 125, 126].contains(key) else { return nil }
        let forward = key == 124 || key == 125
        if let origin = frames[ids[current]] {
            let horizontal = key == 123 || key == 124
            let candidates = ids.indices.compactMap { index -> (Int, CGFloat)? in
                guard index != current, let rect = frames[ids[index]] else { return nil }
                let primary = horizontal ? rect.midX - origin.midX : rect.midY - origin.midY
                let cross = horizontal ? abs(rect.midY - origin.midY) : abs(rect.midX - origin.midX)
                guard forward ? primary > 1 : primary < -1 else { return nil }
                return (index, abs(primary) + cross * 3)
            }
            if let next = candidates.min(by: { $0.1 < $1.1 }) { return next.0 }
        }
        let next = current + (forward ? 1 : -1)
        guard ids.indices.contains(next) else { return nil }
        return frames[ids[current]] == nil || frames[ids[next]] == nil ? next : nil
    }
}
