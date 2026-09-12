import Foundation
import Photos

enum PhotoLibrarySaver {
    nonisolated static func savePNGData(_ data: Data) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
        }
    }
}
