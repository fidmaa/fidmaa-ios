import AVFoundation
import SwiftUI

/// Live, mirrored selfie preview backed by `AVCaptureVideoPreviewLayer`.
/// Rotation is applied by `CameraController` via `AVCaptureDevice.RotationCoordinator`.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let onLayerReady: (AVCaptureVideoPreviewLayer) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        onLayerReady(view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer {
            // layerClass guarantees the type.
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}
