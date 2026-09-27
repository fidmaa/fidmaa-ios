import AVFoundation
import os

/// Delegate for one capture. Calls `completion` exactly once.
final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    private let distance: Float?
    private let completion: (Result<CaptureResult, Error>) -> Void
    /// Set when a photo was handed to the exporter; the exporter then owns the completion.
    private var didReceivePhoto = false

    private static let logger = Logger(subsystem: "com.fidmaa.pic", category: "capture")

    init(distance: Float?, completion: @escaping (Result<CaptureResult, Error>) -> Void) {
        self.distance = distance
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            Self.logger.error("Photo processing failed: \(error.localizedDescription, privacy: .public)")
            return // reported in didFinishCaptureFor
        }
        didReceivePhoto = true
        let distance = self.distance
        let completion = self.completion
        Task.detached(priority: .userInitiated) {
            do {
                completion(.success(try await CaptureExporter.export(photo: photo, distance: distance)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        guard !didReceivePhoto else { return }
        completion(.failure(error ?? CaptureExportError.noPhoto))
    }
}
