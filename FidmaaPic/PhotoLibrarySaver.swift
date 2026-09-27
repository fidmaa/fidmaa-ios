import Foundation
import Photos

enum PhotoLibraryError: LocalizedError {
    case notAuthorized

    var errorDescription: String? {
        String(localized: "Brak zgody na zapis do Zdjęć — włącz w Ustawieniach.")
    }
}

enum PhotoLibrarySaver {
    /// Adds the HEIC (with embedded depth and mattes) to the Photos library as-is.
    static func save(_ data: Data) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw PhotoLibraryError.notAuthorized }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
    }
}
