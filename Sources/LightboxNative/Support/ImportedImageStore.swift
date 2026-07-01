import Foundation
import UniformTypeIdentifiers

enum ImportedImageStore {
    static func persist(_ sourceURL: URL, libraryFolder: URL, preferredName: String? = nil) -> URL? {
        LightboxLibraryStore.copyIntoLibrary(
            sourceURL,
            libraryFolder: libraryFolder,
            preferredName: preferredName
        )
    }

    static func persist(
        data: Data,
        suggestedName: String?,
        typeIdentifier: String,
        libraryFolder: URL
    ) -> URL? {
        let fallbackExtension = UTType(typeIdentifier)?.preferredFilenameExtension ?? "png"
        return LightboxLibraryStore.copyDataIntoLibrary(
            data,
            suggestedName: suggestedName,
            pathExtension: fallbackExtension,
            libraryFolder: libraryFolder
        )
    }
}
