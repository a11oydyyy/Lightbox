import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reads property dictionaries only; never creates a decoded image or mutates the source.
struct PreviewMetadata: Sendable {
    struct Entry: Identifiable, Sendable {
        let label: String
        let value: String
        var id: String { label }
    }
    var capture: [Entry] = []
    var image: [Entry] = []
    var file: [Entry] = []
    var exposureSummary: String = ""
    var imagePropertiesAvailable = false

    static func read(url: URL) -> PreviewMetadata {
        let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] }
        var result = parse(properties ?? [:])
        result.imagePropertiesAvailable = properties != nil
        if let type = source.flatMap({ CGImageSourceGetType($0) }),
           let format = UTType(type as String) {
            result.image.insert(.init(label: "Format", value: format.localizedDescription ?? format.identifier), at: 0)
        }
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey]) {
            if let size = values.fileSize {
                result.file.append(.init(label: "File size", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))
            }
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .medium
            if let date = values.creationDate { result.file.append(.init(label: "Created", value: formatter.string(from: date))) }
            if let date = values.contentModificationDate { result.file.append(.init(label: "Modified", value: formatter.string(from: date))) }
        }
        result.file.append(.init(label: "Path", value: url.path))
        return result
    }

    static func parse(_ properties: [String: Any]) -> PreviewMetadata {
        var result = PreviewMetadata()
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        func text(_ dictionary: [String: Any], _ key: String) -> String? {
            guard let value = dictionary[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        func number(_ dictionary: [String: Any], _ key: String) -> Double? {
            guard let value = dictionary[key] as? NSNumber, value.doubleValue.isFinite else { return nil }
            return value.doubleValue
        }
        func add(_ label: String, _ value: String?, to entries: inout [Entry]) {
            if let value { entries.append(.init(label: label, value: value)) }
        }
        let make = text(tiff, "Make")
        let model = text(tiff, "Model")
        let camera = shortCameraName(make: make, model: model)
        add("Camera", camera, to: &result.capture)
        add("Lens", text(exif, "LensModel"), to: &result.capture)
        var exposure: [String] = []
        if let aperture = number(exif, "FNumber"), aperture > 0 {
            let value = "ƒ/\(decimal(aperture))"
            add("Aperture", value, to: &result.capture); exposure.append(value)
        }
        if let seconds = number(exif, "ExposureTime"), let value = shutter(seconds) {
            add("Shutter", value, to: &result.capture); exposure.append(value)
        }
        if let iso = (exif["ISOSpeedRatings"] as? [NSNumber])?.first?.doubleValue, iso.isFinite, iso > 0 {
            let value = "ISO \(decimal(iso))"
            add("Sensitivity", value, to: &result.capture); exposure.append(value)
        }
        if let focal = number(exif, "FocalLength"), focal > 0 {
            let value = "\(decimal(focal)) mm"
            add("Focal length", value, to: &result.capture); exposure.append(value)
        }
        if let focal = number(exif, "FocalLenIn35mmFilm"), focal > 0 { add("35 mm equivalent", "\(decimal(focal)) mm", to: &result.capture) }
        if let bias = number(exif, "ExposureBiasValue") { add("Exposure bias", "\(bias > 0 ? "+" : "")\(decimal(bias)) EV", to: &result.capture) }
        if let date = text(exif, "DateTimeOriginal") {
            // Preserve camera wall time; do not invent the computer's time zone.
            add("Captured", [date, text(exif, "OffsetTimeOriginal")].compactMap { $0 }.joined(separator: " "), to: &result.capture)
        }
        result.exposureSummary = exposure.joined(separator: " · ")
        add("Color profile", text(properties, kCGImagePropertyProfileName as String), to: &result.image)
        add("Color model", text(properties, kCGImagePropertyColorModel as String), to: &result.image)
        if let depth = number(properties, kCGImagePropertyDepth as String), depth > 0 { add("Bit depth", "\(decimal(depth)) bit", to: &result.image) }
        if let x = number(properties, kCGImagePropertyDPIWidth as String), let y = number(properties, kCGImagePropertyDPIHeight as String), x > 0, y > 0 {
            add("Print resolution", "\(decimal(x)) × \(decimal(y)) ppi", to: &result.image)
        }
        add("Software", text(tiff, "Software"), to: &result.file)
        add("Author", text(tiff, "Artist"), to: &result.file)
        add("Copyright", text(tiff, "Copyright"), to: &result.file)
        return result
    }

    static func shortCameraName(make: String?, model: String?) -> String? {
        let brands = ["RICOH", "Canon", "Nikon", "Sony", "FUJIFILM", "Panasonic", "Leica", "Hasselblad", "Olympus", "PENTAX", "Apple", "Google", "Samsung", "DJI"]
        let manufacturer = make?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let brand = brands.first { manufacturer.localizedCaseInsensitiveContains($0) }
            ?? manufacturer.replacingOccurrences(of: #"(?i)[,\s]+(?:corporation|corp\.?|inc\.?|co\.?|ltd\.?|company)\b.*$"#, with: "", options: .regularExpression)
        guard let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else {
            return brand.isEmpty ? nil : brand
        }
        guard !brand.isEmpty else { return model }
        if model.lowercased().hasPrefix(brand.lowercased()) {
            return brand + model.dropFirst(brand.count)
        }
        return "\(brand) \(model)"
    }

    static func decimal(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never)) }
    static func shutter(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        if seconds < 1 {
            let reciprocal = 1 / seconds
            if reciprocal.isFinite, abs(reciprocal - reciprocal.rounded()) < 0.02 * reciprocal {
                return "1/\(decimal(reciprocal.rounded())) s"
            }
        }
        return "\(seconds.formatted(.number.precision(.fractionLength(0...4)).grouping(.never))) s"
    }
}
