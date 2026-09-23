import Photos

/// Saves finished clips to the photo library.
enum MediaSaver {

    enum Failure: LocalizedError {
        case permissionDenied
        case saveFailed(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                "facetrkr needs permission to add videos to your photo library."
            case .saveFailed(let why):
                "Couldn't save the video: \(why)"
            }
        }
    }

    /// Add-only authorisation, deliberately.
    ///
    /// The app never reads the library, so asking for read access would be
    /// both a worse prompt for the user and more data than the app needs.
    /// Add-only is also unaffected by the limited-library selection.
    static func saveToPhotoLibrary(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw Failure.permissionDenied
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: url, options: nil)
            }
        } catch {
            throw Failure.saveFailed(error.localizedDescription)
        }
    }
}
