import AVFoundation
import FidmaaCore
import ImageIO
import os
import UIKit

enum CaptureExportError: LocalizedError {
    case noPhoto
    case noPhotoData
    case depthNotFloat32

    var errorDescription: String? {
        switch self {
        case .noPhoto: "Aparat nie zwrócił zdjęcia."
        case .noPhotoData: "Nie udało się zakodować zdjęcia HEIC."
        case .depthNotFloat32: "Mapa głębi nie jest w formacie Float32."
        }
    }
}

/// Writes one capture to `Documents/<timestamp>/` and to the Photos library.
/// Individual file failures are logged and reported as warnings; the rest is still written.
enum CaptureExporter {
    private static let logger = Logger(subsystem: "com.fidmaa.pic", category: "export")

    private static let semanticMattes: [(AVSemanticSegmentationMatte.MatteType, String, WritableKeyPath<MatteFiles, String?>)] = [
        (.hair, "hair.png", \.hair),
        (.skin, "skin.png", \.skin),
        (.teeth, "teeth.png", \.teeth),
        (.glasses, "glasses.png", \.glasses),
    ]

    static func export(photo: AVCapturePhoto, distance: Float?, stack: StackCapture,
                       date: Date = Date()) async throws -> CaptureResult {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
        let folder = try ExportNaming.createUniqueFolder(in: documents, date: date)
        var warnings: [String] = []

        func attempt(_ name: String, _ body: () throws -> Void) {
            do {
                try body()
            } catch {
                logger.error("\(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                warnings.append("\(name): \(error.localizedDescription)")
            }
        }

        // Depth
        var depthInfo: DepthInfo?
        var correctedDepth: (values: [Float], width: Int, height: Int)?
        var calibration: CalibrationInfo?
        var accuracy = DepthAccuracyLabel.unknown
        if let original = photo.depthData {
            let depth = original.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
            let map = depth.depthDataMap
            accuracy = label(depth.depthDataAccuracy)
            var info = DepthInfo(width: CVPixelBufferGetWidth(map), height: CVPixelBufferGetHeight(map),
                                 accuracy: accuracy, quality: depth.depthDataQuality == .high ? "high" : "low",
                                 isFiltered: depth.isDepthDataFiltered,
                                 originalPixelFormat: FourCC.string(original.depthDataType))
            if var values = PixelBufferAccess.withFloat32(map, {
                DepthRaw.packed($0, width: $1, height: $2, rowStride: $3)
            }) {
                let width = info.width
                let height = info.height
                let photoCenter = values.withUnsafeBufferPointer {
                    DistanceEstimator.medianCenterDepth($0, width: width, height: height, rowStride: width)
                }
                let streamCenter = stack.frames.last.flatMap { frame in
                    frame.values.withUnsafeBufferPointer {
                        DistanceEstimator.medianCenterDepth($0, width: frame.width, height: frame.height,
                                                            rowStride: frame.width)
                    }
                }
                info.photoCenterMeters = photoCenter
                info.streamCenterMeters = streamCenter
                info.interpretation = DepthInterpretation.choose(photoCenter: photoCenter, streamCenter: streamCenter)
                switch info.interpretation {
                case .inverted:
                    values = DepthInterpretation.inverted(values)
                    logger.info("Photo depth inverted to match stream (photo \(photoCenter ?? .nan), stream \(streamCenter ?? .nan))")
                case .unverified:
                    warnings.append("Nie dało się sprawdzić głębi zdjęcia względem strumienia")
                case .asLabelled:
                    break
                }
                attempt("depth.tiff") {
                    try ImageFileWriter.writeFloat32TIFF(values: values, width: width, height: height,
                                                         to: folder.appendingPathComponent("depth.tiff"))
                }
                attempt("depth.f32") {
                    try DepthRaw.littleEndianData(frames: [values]).write(to: folder.appendingPathComponent("depth.f32"))
                }
                if info.interpretation != .unverified { correctedDepth = (values, width, height) }
            } else {
                warnings.append("depth.f32: \(CaptureExportError.depthNotFloat32.localizedDescription)")
            }
            depthInfo = info
            calibration = depth.cameraCalibrationData.map(makeCalibration)
            if calibration == nil { warnings.append("Brak danych kalibracji kamery") }
        } else {
            warnings.append("Brak danych głębi w zdjęciu")
        }
        if accuracy == .relative {
            warnings.append("Głębia ma dokładność RELATIVE, nie absolute")
        }

        // HEIC (folder + Photos): replace iOS's mislabelled depth with verified true disparity.
        guard let originalHEIC = photo.fileDataRepresentation() else { throw CaptureExportError.noPhotoData }
        var heic = originalHEIC
        depthInfo?.heicDepth = "ios-original"
        if let original = photo.depthData, let corrected = correctedDepth {
            do {
                let replacement = try HEICComposer.trueDisparity(from: original, meters: corrected.values,
                                                                 width: corrected.width, height: corrected.height)
                guard let data = photo.fileDataRepresentation(with: DepthReplacingCustomizer(depth: replacement)) else {
                    throw CaptureExportError.noPhotoData
                }
                try HEICComposer.verify(data: data, expected: corrected.values,
                                        width: corrected.width, height: corrected.height)
                heic = data
                depthInfo?.heicDepth = "true-disparity"
            } catch {
                logger.error("Corrected HEIC depth failed, keeping iOS original: \(error.localizedDescription, privacy: .public)")
                warnings.append("HEIC: zostawiono oryginalną głębię iOS (\(error.localizedDescription))")
            }
        }
        attempt("photo.heic") { try heic.write(to: folder.appendingPathComponent("photo.heic")) }

        // Mattes
        var mattes = MatteFiles()
        if let portrait = photo.portraitEffectsMatte {
            attempt("portrait.png") {
                try ImageFileWriter.writeGray8PNG(portrait.mattingImage, to: folder.appendingPathComponent("portrait.png"))
                mattes.portrait = "portrait.png"
            }
        }
        for (type, fileName, keyPath) in semanticMattes {
            guard let matte = photo.semanticSegmentationMatte(for: type) else { continue }
            attempt(fileName) {
                try ImageFileWriter.writeGray8PNG(matte.mattingImage, to: folder.appendingPathComponent(fileName))
                mattes[keyPath: keyPath] = fileName
            }
        }
        if mattes.portrait == nil && mattes.hair == nil && mattes.skin == nil {
            warnings.append("Brak masek — czy twarz była w kadrze?")
        }

        // Multi-frame stack
        var stackInfo: StackInfo?
        attempt("stos klatek") {
            stackInfo = try StackExporter.export(stack, to: folder, warnings: &warnings)
        }

        // Metadata
        let dims = photo.resolvedSettings.photoDimensions
        let orientation = (photo.metadata[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
        let metadata = CaptureMetadata(
            captureDate: date,
            deviceModel: DeviceInfo.modelIdentifier,
            systemVersion: DeviceInfo.systemVersion,
            depth: depthInfo,
            image: ImageInfo(width: Int(dims.width), height: Int(dims.height), exifOrientation: orientation,
                             mirrored: ExifOrientation.isMirrored(orientation)),
            calibration: calibration,
            mattes: mattes,
            distanceAtCaptureMeters: distance,
            stack: stackInfo,
            depthMapCalibration: stack.frames.last?.calibration.map(makeCalibration))
        attempt("calibration.json") {
            try metadata.jsonData().write(to: folder.appendingPathComponent("calibration.json"))
        }

        // Photos library
        do {
            try await PhotoLibrarySaver.save(heic)
        } catch {
            logger.error("Saving to Photos failed: \(error.localizedDescription, privacy: .public)")
            warnings.append("Zdjęcia: \(error.localizedDescription)")
        }

        let thumbnail = ThumbnailLoader.thumbnail(from: heic, maxPixelSize: 320)
        logger.info("Exported \(folder.lastPathComponent, privacy: .public), accuracy \(accuracy.rawValue, privacy: .public)")
        return CaptureResult(folder: folder, accuracy: accuracy, thumbnail: thumbnail,
                             framesUsed: stackInfo?.framesUsed, framesCaptured: stackInfo?.framesCaptured,
                             photoDepthFiltered: depthInfo?.isFiltered ?? false,
                             warnings: warnings)
    }

    private static func label(_ accuracy: AVDepthData.Accuracy) -> DepthAccuracyLabel {
        switch accuracy {
        case .absolute: .absolute
        case .relative: .relative
        @unknown default: .unknown
        }
    }

    static func makeCalibration(_ c: AVCameraCalibrationData) -> CalibrationInfo {
        let i = c.intrinsicMatrix
        let e = c.extrinsicMatrix
        return CalibrationInfo(
            intrinsicMatrix: Matrix.rowMajor(columns: [i.columns.0, i.columns.1, i.columns.2].map { [$0.x, $0.y, $0.z] }),
            intrinsicMatrixReferenceDimensions: Size2D(width: Double(c.intrinsicMatrixReferenceDimensions.width),
                                                       height: Double(c.intrinsicMatrixReferenceDimensions.height)),
            extrinsicMatrix: Matrix.rowMajor(columns: [e.columns.0, e.columns.1, e.columns.2, e.columns.3].map { [$0.x, $0.y, $0.z] }),
            pixelSizeMillimeters: c.pixelSize,
            lensDistortionCenter: Point2D(x: Double(c.lensDistortionCenter.x), y: Double(c.lensDistortionCenter.y)),
            lensDistortionLookupTable: c.lensDistortionLookupTable.map(DepthRaw.floats(fromNativeData:)) ?? [],
            inverseLensDistortionLookupTable: c.inverseLensDistortionLookupTable.map(DepthRaw.floats(fromNativeData:)) ?? [])
    }
}

/// Swaps the depth written into the photo's file data (AVFoundation's official hook for this).
private final class DepthReplacingCustomizer: NSObject, AVCapturePhotoFileDataRepresentationCustomizer {
    private let depth: AVDepthData

    init(depth: AVDepthData) {
        self.depth = depth
    }

    func replacementDepthData(for photo: AVCapturePhoto) -> AVDepthData? {
        depth
    }
}
