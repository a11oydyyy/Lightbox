import Foundation

/// Narrows the gallery by what a file is, beyond its name and Finder tags:
/// kind, orientation, pixel size, date added, file size and whether Camera
/// Raw has settings for it (`LightboxAsset.hasCameraRawSettings`). Every part is
/// "any" by default; the parts combine with each other, the name search, the
/// tag filter and "include subfolders".
///
/// A file whose value is not known yet (an image still waiting for its size,
/// a file without a size or date) does not match a part that asks for it; it
/// appears once the metadata pass has read it.
struct GalleryAttributeFilter: Equatable, Hashable, Sendable, Codable {
    enum Kind: String, CaseIterable, Codable, Sendable {
        case any
        /// Images other than RAW (JPEG, HEIC, PNG, TIFF…).
        case photos
        case raw
        case videos
        /// Every other file that is neither an image nor a video.
        case documents
    }

    enum Orientation: String, CaseIterable, Codable, Sendable {
        case any, landscape, portrait, square
    }

    /// By the long edge, in pixels.
    enum PixelSize: String, CaseIterable, Codable, Sendable {
        case any, under2000, atLeast2000, atLeast4000, atLeast6000
    }

    /// By Date Added (the gallery's date sort), in the current calendar.
    enum AddedDate: String, CaseIterable, Codable, Sendable {
        case any, today, thisWeek, thisMonth, thisYear
    }

    /// In Finder's decimal units (1 MB = 1,000,000 bytes).
    enum FileSize: String, CaseIterable, Codable, Sendable {
        case any, under1MB, from1To10MB, from10To50MB, over50MB
    }

    /// Images with or without Camera Raw (or Lightroom) develop settings.
    enum CameraRaw: String, CaseIterable, Codable, Sendable {
        case any, edited, unedited
    }

    var kind = Kind.any
    var orientation = Orientation.any
    var pixelSize = PixelSize.any
    var addedDate = AddedDate.any
    var fileSize = FileSize.any
    var cameraRaw = CameraRaw.any

    var isActive: Bool { self != GalleryAttributeFilter() }

    var activeCount: Int {
        [kind != .any, orientation != .any, pixelSize != .any, addedDate != .any, fileSize != .any, cameraRaw != .any]
            .filter { $0 }.count
    }

    /// Whether matching needs every image's pixel size.
    var needsDimensions: Bool { orientation != .any || pixelSize != .any }

    /// Whether matching waits on the background metadata pass (sizes, or
    /// Camera Raw settings, which it reads with Finder tags).
    var needsMetadataPass: Bool { needsDimensions || cameraRaw != .any }

    /// A test for one file, with the date ranges worked out once.
    func matcher(now: Date = Date(), calendar: Calendar = .current) -> (LightboxAsset) -> Bool {
        guard isActive else { return { _ in true } }
        let addedRange: DateInterval? = switch addedDate {
        case .any: nil
        case .today: calendar.dateInterval(of: .day, for: now)
        case .thisWeek: calendar.dateInterval(of: .weekOfYear, for: now)
        case .thisMonth: calendar.dateInterval(of: .month, for: now)
        case .thisYear: calendar.dateInterval(of: .year, for: now)
        }
        let filter = self
        return { asset in
            guard filter.kind == .any || Self.kind(of: asset) == filter.kind else { return false }
            if filter.needsDimensions {
                guard asset.isImage, asset.metadataLoaded, asset.width > 0, asset.height > 0 else { return false }
                guard filter.matchesOrientation(width: asset.width, height: asset.height),
                      filter.matchesPixelSize(longEdge: max(asset.width, asset.height)) else { return false }
            }
            if let addedRange {
                guard asset.addedAt != .distantPast, addedRange.contains(asset.addedAt) else { return false }
            }
            if filter.fileSize != .any {
                guard let bytes = asset.fileSize, filter.matchesFileSize(bytes) else { return false }
            }
            if filter.cameraRaw != .any {
                // Not checked yet matches neither, as an unknown size matches no size part.
                guard asset.isImage, let edited = asset.hasCameraRawSettings,
                      edited == (filter.cameraRaw == .edited) else { return false }
            }
            return true
        }
    }

    static func kind(of asset: LightboxAsset) -> Kind {
        let fileExtension = (asset.originalName as NSString).pathExtension.lowercased()
        if asset.isImage {
            return LightboxAsset.rawImageExtensions.contains(fileExtension) ? .raw : .photos
        }
        return videoExtensions.contains(fileExtension) ? .videos : .documents
    }

    static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "webm", "mts", "m2ts", "3gp", "mpg", "mpeg",
        "wmv", "flv", "hevc", "braw", "r3d", "mxf", "insv"
    ]

    private func matchesOrientation(width: CGFloat, height: CGFloat) -> Bool {
        // Within 1% counts as square: cropped "squares" are often a pixel off.
        let isSquare = max(width, height) / min(width, height) <= 1.01
        return switch orientation {
        case .any: true
        case .square: isSquare
        case .landscape: !isSquare && width > height
        case .portrait: !isSquare && height > width
        }
    }

    private func matchesPixelSize(longEdge: CGFloat) -> Bool {
        switch pixelSize {
        case .any: true
        case .under2000: longEdge < 2000
        case .atLeast2000: longEdge >= 2000
        case .atLeast4000: longEdge >= 4000
        case .atLeast6000: longEdge >= 6000
        }
    }

    private func matchesFileSize(_ bytes: Int64) -> Bool {
        let megabyte: Int64 = 1_000_000
        return switch fileSize {
        case .any: true
        case .under1MB: bytes < megabyte
        case .from1To10MB: bytes >= megabyte && bytes < 10 * megabyte
        case .from10To50MB: bytes >= 10 * megabyte && bytes < 50 * megabyte
        case .over50MB: bytes >= 50 * megabyte
        }
    }
}

// In an extension, so the memberwise initializers stay.
extension GalleryAttributeFilter {
    /// Parts missing from a saved filter (saved before they existed) are "any".
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .any
        orientation = try container.decodeIfPresent(Orientation.self, forKey: .orientation) ?? .any
        pixelSize = try container.decodeIfPresent(PixelSize.self, forKey: .pixelSize) ?? .any
        addedDate = try container.decodeIfPresent(AddedDate.self, forKey: .addedDate) ?? .any
        fileSize = try container.decodeIfPresent(FileSize.self, forKey: .fileSize) ?? .any
        cameraRaw = try container.decodeIfPresent(CameraRaw.self, forKey: .cameraRaw) ?? .any
    }
}
