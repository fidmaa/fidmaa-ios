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

    static func export(photo: AVCapturePhoto, distance: Float?, date: Date = Date()) async throws -> CaptureResult {
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

        guard let heic = photo.fileDataRepresentation() else { throw CaptureExportError.noPhotoData }
        attempt("photo.heic") { try heic.write(to: folder.appendingPathComponent("photo.heic")) }

        // Depth
        var depthInfo: DepthInfo?
        var calibration: CalibrationInfo?
        var accuracy = DepthAccuracyLabel.unknown
        if let original = photo.depthData {
            let depth = original.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
            let map = depth.depthDataMap
            accuracy = label(depth.depthDataAccuracy)
            depthInfo = DepthInfo(width: CVPixelBufferGetWidth(map), height: CVPixelBufferGetHeight(map),
                                  accuracy: accuracy, quality: depth.depthDataQuality == .high ? "high" : "low",
                                  isFiltered: depth.isDepthDataFiltered,
                                  originalPixelFormat: FourCC.string(original.depthDataType))
            attempt("depth.tiff") {
                try ImageFileWriter.writeFloat32TIFF(map, to: folder.appendingPathComponent("depth.tiff"))
            }
            attempt("depth.f32") {
                guard let data = PixelBufferAccess.withFloat32(map, {
                    DepthRaw.littleEndianData($0, width: $1, height: $2, rowStride: $3)
                }) else { throw CaptureExportError.depthNotFloat32 }
                try data.write(to: folder.appendingPathComponent("depth.f32"))
            }
            calibration = depth.cameraCalibrationData.map(makeCalibration)
            if calibration == nil { warnings.append("Brak danych kalibracji kamery") }
        } else {
            warnings.append("Brak danych głębi w zdjęciu")
        }
        if accuracy == .relative {
            warnings.append("Głębia ma dokładność RELATIVE, nie absolute")
        }

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
            distanceAtCaptureMeters: distance)
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

        let thumbnail = UIImage(data: heic)?.preparingThumbnail(of: CGSize(width: 240, height: 320))
        logger.info("Exported \(folder.lastPathComponent, privacy: .public), accuracy \(accuracy.rawValue, privacy: .public)")
        return CaptureResult(folder: folder, accuracy: accuracy, thumbnail: thumbnail, warnings: warnings)
    }

    private static func label(_ accuracy: AVDepthData.Accuracy) -> DepthAccuracyLabel {
        switch accuracy {
        case .absolute: .absolute
        case .relative: .relative
        @unknown default: .unknown
        }
    }

    private static func makeCalibration(_ c: AVCameraCalibrationData) -> CalibrationInfo {
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
