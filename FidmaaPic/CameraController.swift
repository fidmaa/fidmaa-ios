import AVFoundation
import FidmaaCore
import Observation
import os
import QuartzCore
import UIKit

enum CameraError: LocalizedError {
    case accessDenied
    case noTrueDepthCamera
    case cannotAddInput
    case cannotAddPhotoOutput
    case depthNotSupported

    var errorDescription: String? {
        switch self {
        case .accessDenied: "Brak zgody na aparat. Włącz ją w Ustawieniach → Fidmaa Pic."
        case .noTrueDepthCamera: "To urządzenie nie ma przedniej kamery TrueDepth."
        case .cannotAddInput: "Nie można podłączyć kamery TrueDepth do sesji."
        case .cannotAddPhotoOutput: "Nie można skonfigurować wyjścia zdjęć."
        case .depthNotSupported: "Kamera nie udostępnia danych głębi w żadnym formacie."
        }
    }
}

struct CaptureResult {
    let folder: URL
    let accuracy: DepthAccuracyLabel
    let thumbnail: UIImage?
    let framesUsed: Int?
    let framesCaptured: Int?
    let warnings: [String]
}

enum CaptureConfig {
    /// Raw (unfiltered) depth for measurements; holes stay NaN/0 instead of being interpolated.
    static let isDepthDataFiltered = false
    /// Minimum interval between live distance updates.
    static let distanceUpdateInterval: CFTimeInterval = 0.1
    /// Streamed depth frames from this many seconds before the shutter are averaged.
    static let stackWindowSeconds = 0.5
    /// Frames rotated more than this from the reference (last) frame are not averaged.
    static let stackRotationThresholdDegrees = 0.35
    /// Fewer used frames than this triggers a "hold steadier" warning.
    static let stackMinimumFrames = 5
    /// Ring buffer size (~1.5 s at 30 fps).
    static let frameBufferCapacity = 45
    /// Minimum interval between colored depth view updates (~15 fps).
    static let depthViewUpdateInterval: CFTimeInterval = 1.0 / 15
    /// The selfie preview is mirrored; mirror the depth view the same way.
    static let depthViewMirrored = true
    /// Extra clockwise rotation (screen space, before mirroring) found on iPhone 17: without it the
    /// depth view was 90° clockwise off from the camera preview.
    static let depthViewExtraRotation: CGFloat = 90
}

/// Streamed depth frames plus matching motion samples, taken at the shutter.
struct StackCapture {
    let frames: [DepthFrame]
    /// Parallel to `frames`; nil where no motion sample was close enough.
    let motion: [MotionRecorder.Sample?]
    let motionAvailable: Bool
}

@Observable
final class CameraController: NSObject {
    enum State: Equatable {
        case idle
        case running
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var distance: DistanceStatus = .noData
    private(set) var isCapturing = false
    private(set) var lastResult: CaptureResult?
    private(set) var lastError: String?
    /// Latest colored depth frame (sensor orientation); only produced while the depth view is shown.
    private(set) var depthImage: CGImage?
    /// Clockwise rotation that makes sensor-oriented frames upright on screen.
    private(set) var previewRotationAngle: CGFloat = 90
    var isDepthViewActive = false {
        didSet {
            let active = isDepthViewActive
            depthViewEnabled.withLock { $0 = active }
            if !active { depthImage = nil }
        }
    }

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "fidmaa.session")
    @ObservationIgnored private let depthQueue = DispatchQueue(label: "fidmaa.depth")
    @ObservationIgnored private let photoOutput = AVCapturePhotoOutput()
    @ObservationIgnored private let depthOutput = AVCaptureDepthDataOutput()
    /// sessionQueue only.
    @ObservationIgnored private var isConfigured = false
    /// sessionQueue only.
    @ObservationIgnored private var processors: [Int64: PhotoCaptureProcessor] = [:]
    /// depthQueue only.
    @ObservationIgnored private var lastDistanceUpdate: CFTimeInterval = 0
    @ObservationIgnored private let latestMedian = OSAllocatedUnfairLock<Float?>(initialState: nil)
    @ObservationIgnored private let frameBuffer = DepthFrameBuffer(capacity: CaptureConfig.frameBufferCapacity)
    @ObservationIgnored private let motion = MotionRecorder()
    @ObservationIgnored private let depthViewEnabled = OSAllocatedUnfairLock(initialState: false)
    /// depthQueue only.
    @ObservationIgnored private var lastDepthViewUpdate: CFTimeInterval = 0
    /// sessionQueue only.
    @ObservationIgnored private var device: AVCaptureDevice?
    /// main thread only.
    @ObservationIgnored private var isStarting = false
    /// main thread only. Rotation comes from the device's sensor orientation, not a fixed angle.
    @ObservationIgnored private weak var previewLayer: AVCaptureVideoPreviewLayer?
    @ObservationIgnored private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored private var previewAngleObservation: NSKeyValueObservation?

    private static let logger = Logger(subsystem: "com.fidmaa.pic", category: "camera")

    // MARK: - Lifecycle (call on main thread)

    func start() {
        if case .failed = state { return }
        guard !isStarting else { return }
        isStarting = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { self.configureAndRun() } else { self.fail(CameraError.accessDenied) }
                }
            }
        default:
            fail(CameraError.accessDenied)
        }
    }

    func stop() {
        motion.stop()
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func configureAndRun() {
        sessionQueue.async {
            do {
                if !self.isConfigured {
                    try self.configureSession()
                    self.isConfigured = true
                }
                if !self.session.isRunning { self.session.startRunning() }
                let device = self.device
                DispatchQueue.main.async {
                    self.isStarting = false
                    self.state = .running
                    self.motion.start()
                    self.setUpRotation(device: device)
                }
            } catch {
                Self.logger.error("Session configuration failed: \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async { self.fail(error) }
            }
        }
    }

    /// Call on main thread once the preview layer exists.
    func attach(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        sessionQueue.async {
            let device = self.device
            DispatchQueue.main.async { self.setUpRotation(device: device) }
        }
    }

    /// Main thread. Needs both the configured device and the preview layer.
    private func setUpRotation(device: AVCaptureDevice?) {
        guard rotationCoordinator == nil, let device, let previewLayer else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        applyPreviewRotation(coordinator.videoRotationAngleForHorizonLevelPreview)
        previewAngleObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview,
                                                      options: .new) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            DispatchQueue.main.async { self?.applyPreviewRotation(angle) }
        }
        Self.logger.info("Rotation: preview \(coordinator.videoRotationAngleForHorizonLevelPreview), capture \(coordinator.videoRotationAngleForHorizonLevelCapture)")
    }

    private func applyPreviewRotation(_ angle: CGFloat) {
        guard let connection = previewLayer?.connection, connection.isVideoRotationAngleSupported(angle) else {
            Self.logger.error("Preview rotation \(angle) not supported")
            return
        }
        connection.videoRotationAngle = angle
        previewRotationAngle = angle
    }

    private func fail(_ error: Error) {
        isStarting = false
        state = .failed(error.localizedDescription)
    }

    // MARK: - Session configuration (sessionQueue)

    private func configureSession() throws {
        guard let device = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) else {
            throw CameraError.noTrueDepthCamera
        }
        self.device = device
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraError.cannotAddInput }
        session.addInput(input)

        guard session.canAddOutput(photoOutput) else { throw CameraError.cannotAddPhotoOutput }
        session.addOutput(photoOutput)

        if session.canAddOutput(depthOutput) {
            session.addOutput(depthOutput)
            // Raw depth: frames are averaged ourselves; the distance median ignores holes.
            depthOutput.isFilteringEnabled = false
            depthOutput.alwaysDiscardsLateDepthData = true
            depthOutput.setDelegate(self, callbackQueue: depthQueue)
        } else {
            Self.logger.error("Cannot add AVCaptureDepthDataOutput; live distance hints disabled")
        }

        let format = try selectVideoFormat(for: device)

        photoOutput.maxPhotoQualityPrioritization = .quality
        guard photoOutput.isDepthDataDeliverySupported else { throw CameraError.depthNotSupported }
        photoOutput.isDepthDataDeliveryEnabled = true
        photoOutput.isPortraitEffectsMatteDeliveryEnabled = photoOutput.isPortraitEffectsMatteDeliverySupported
        photoOutput.enabledSemanticSegmentationMatteTypes = photoOutput.availableSemanticSegmentationMatteTypes
        if let largest = format.supportedMaxPhotoDimensions.max(by: { Self.area($0) < Self.area($1) }) {
            photoOutput.maxPhotoDimensions = largest
        }

        try selectDepthFormat(for: device, videoFormat: format)

        Self.logger.info("""
            Configured TrueDepth: format \(format.description, privacy: .public), \
            photo sizes \(format.supportedMaxPhotoDimensions.map { "\($0.width)x\($0.height)" }, privacy: .public), \
            chosen \(self.photoOutput.maxPhotoDimensions.width)x\(self.photoOutput.maxPhotoDimensions.height), \
            depth \(device.activeDepthDataFormat?.description ?? "none", privacy: .public), \
            mattes \(self.photoOutput.enabledSemanticSegmentationMatteTypes.map(\.rawValue), privacy: .public)
            """)
    }

    /// Picks the depth-capable format preferring Float32 depth, 8-bit full-range video, then photo size.
    private func selectVideoFormat(for device: AVCaptureDevice) throws -> AVCaptureDevice.Format {
        let candidates = device.formats.filter { !$0.supportedDepthDataFormats.isEmpty }
        guard let best = candidates.max(by: { Self.score($0) < Self.score($1) }) else {
            throw CameraError.depthNotSupported
        }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = best
        return best
    }

    private func selectDepthFormat(for device: AVCaptureDevice, videoFormat: AVCaptureDevice.Format) throws {
        let all = videoFormat.supportedDepthDataFormats
        let float32 = all.filter {
            CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat32
        }
        let pool = float32.isEmpty ? all : float32
        guard let best = pool.max(by: { Self.width($0) < Self.width($1) }) else {
            throw CameraError.depthNotSupported
        }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeDepthDataFormat = best
    }

    private static func score(_ format: AVCaptureDevice.Format) -> (Int, Int, Int) {
        let hasFloat32Depth = format.supportedDepthDataFormats.contains {
            CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat32
        }
        let isFullRange8Bit = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let photoArea = format.supportedMaxPhotoDimensions.map(area).max() ?? 0
        return (hasFloat32Depth ? 1 : 0, isFullRange8Bit ? 1 : 0, photoArea)
    }

    private static func area(_ dims: CMVideoDimensions) -> Int { Int(dims.width) * Int(dims.height) }

    private static func width(_ format: AVCaptureDevice.Format) -> Int32 {
        CMVideoFormatDescriptionGetDimensions(format.formatDescription).width
    }

    // MARK: - Capture

    /// Call on main thread.
    func capturePhoto() {
        guard state == .running, !isCapturing else { return }
        isCapturing = true
        lastError = nil
        let distanceAtCapture = latestMedian.withLock { $0 }
        let stackFrames = frameBuffer.snapshot(window: CaptureConfig.stackWindowSeconds)
        let stack = StackCapture(frames: stackFrames,
                                 motion: stackFrames.map { motion.sample(near: $0.timestamp) },
                                 motionAvailable: motion.isAvailable)
        let rotationAngle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture
        sessionQueue.async {
            let settings = self.makePhotoSettings(rotationAngle: rotationAngle)
            let id = settings.uniqueID
            let processor = PhotoCaptureProcessor(distance: distanceAtCapture, stack: stack) { [weak self] outcome in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.isCapturing = false
                    switch outcome {
                    case .success(let result):
                        self.lastResult = result
                    case .failure(let error):
                        Self.logger.error("Capture failed: \(error.localizedDescription, privacy: .public)")
                        self.lastError = error.localizedDescription
                    }
                }
                self.sessionQueue.async { self.processors[id] = nil }
            }
            self.processors[id] = processor
            self.photoOutput.capturePhoto(with: settings, delegate: processor)
        }
    }

    private func makePhotoSettings(rotationAngle: CGFloat?) -> AVCapturePhotoSettings {
        let settings = photoOutput.availablePhotoCodecTypes.contains(.hevc)
            ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            : AVCapturePhotoSettings()
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        settings.photoQualityPrioritization = .quality
        settings.isDepthDataDeliveryEnabled = photoOutput.isDepthDataDeliveryEnabled
        settings.embedsDepthDataInPhoto = true
        settings.isDepthDataFiltered = CaptureConfig.isDepthDataFiltered
        settings.isPortraitEffectsMatteDeliveryEnabled = photoOutput.isPortraitEffectsMatteDeliveryEnabled
        settings.embedsPortraitEffectsMatteInPhoto = true
        settings.enabledSemanticSegmentationMatteTypes = photoOutput.enabledSemanticSegmentationMatteTypes
        settings.embedsSemanticSegmentationMattesInPhoto = true
        if let rotationAngle, let connection = photoOutput.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(rotationAngle) {
                connection.videoRotationAngle = rotationAngle
            } else {
                Self.logger.error("Capture rotation \(rotationAngle) not supported")
            }
        } else {
            Self.logger.error("No rotation coordinator or photo connection; photo keeps sensor orientation")
        }
        return settings
    }
}

// MARK: - Live depth → distance hint

extension CameraController: AVCaptureDepthDataOutputDelegate {
    func depthDataOutput(_ output: AVCaptureDepthDataOutput, didOutput depthData: AVDepthData,
                         timestamp: CMTime, connection: AVCaptureConnection) {
        let depth = depthData.depthDataType == kCVPixelFormatType_DepthFloat32
            ? depthData
            : depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        guard let frame = PixelBufferAccess.withFloat32(depth.depthDataMap, { values, width, height, rowStride in
            DepthFrame(timestamp: CMTimeGetSeconds(timestamp), width: width, height: height,
                       values: DepthRaw.packed(values, width: width, height: height, rowStride: rowStride),
                       calibration: depth.cameraCalibrationData)
        }) else {
            Self.logger.error("Streamed depth is not Float32 after conversion; frame skipped")
            return
        }
        frameBuffer.append(frame)

        let now = CACurrentMediaTime()
        if depthViewEnabled.withLock({ $0 }), now - lastDepthViewUpdate >= CaptureConfig.depthViewUpdateInterval {
            lastDepthViewUpdate = now
            let image = Self.coloredImage(frame)
            DispatchQueue.main.async {
                if self.isDepthViewActive { self.depthImage = image }
            }
        }

        guard now - lastDistanceUpdate >= CaptureConfig.distanceUpdateInterval else { return }
        lastDistanceUpdate = now
        let median = frame.values.withUnsafeBufferPointer {
            DistanceEstimator.medianCenterDepth($0, width: frame.width, height: frame.height, rowStride: frame.width)
        }
        latestMedian.withLock { $0 = median }
        let status = DistanceEstimator.status(forMedian: median)
        DispatchQueue.main.async { self.distance = status }
    }

    private static func coloredImage(_ frame: DepthFrame) -> CGImage? {
        let bytes = DepthColormap.rgba(frame.values)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: frame.width * 4, space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
