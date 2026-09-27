import AVFoundation
import CoreVideo
import FidmaaCore
import Foundation
import ImageIO

enum HEICComposerError: LocalizedError {
    case cannotRead(URL)
    case cannotCreateDestination(URL)
    case noDepthInPhoto
    case cannotCreatePixelBuffer
    case cannotEncodeDepth
    case finalizeFailed(URL)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotRead(let url): String(localized: "Nie można odczytać \(url.lastPathComponent)")
        case .cannotCreateDestination(let url): String(localized: "Nie można utworzyć \(url.lastPathComponent)")
        case .noDepthInPhoto: String(localized: "Zdjęcie nie ma osadzonej głębi")
        case .cannotCreatePixelBuffer: String(localized: "Nie można utworzyć bufora głębi")
        case .cannotEncodeDepth: String(localized: "Nie można zakodować głębi")
        case .finalizeFailed(let url): String(localized: "Nie udało się zapisać \(url.lastPathComponent)")
        case .verificationFailed(let details): String(localized: "Głębia w zapisanym HEIC nie zgadza się z danymi (\(details))")
        }
    }
}

/// Rewrites a capture's HEIC with a given depth map (meters, sensor orientation), keeping the image,
/// its metadata and all mattes. The depth is stored as true disparity (1/m) — the standard HEIC form.
/// (iOS's own file on iPhone 17 stores meters under a "disparity" label.) The file is read back and
/// compared with the input; a mismatch throws instead of silently shipping a broken map.
enum HEICComposer {
    private static let copiedAuxiliaryTypes: [CFString] = [
        kCGImageAuxiliaryDataTypePortraitEffectsMatte,
        kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte,
        kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte,
        kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte,
        kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte,
        kCGImageAuxiliaryDataTypeHDRGainMap,
        kCGImageAuxiliaryDataTypeISOGainMap,
    ]

    static func write(photo: URL, depth values: [Float], width: Int, height: Int, to destination: URL) throws {
        guard let source = CGImageSourceCreateWithURL(photo as CFURL, nil),
              let type = CGImageSourceGetType(source) else { throw HEICComposerError.cannotRead(photo) }
        guard let output = CGImageDestinationCreateWithURL(destination as CFURL, type, 1, nil) else {
            throw HEICComposerError.cannotCreateDestination(destination)
        }
        let properties = [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary
        CGImageDestinationAddImageFromSource(output, source, 0, properties)

        for auxType in copiedAuxiliaryTypes {
            if let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, auxType) {
                CGImageDestinationAddAuxiliaryDataInfo(output, auxType, info)
            }
        }

        guard let originalInfo = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeDisparity)
                ?? CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeDepth),
              let dictionary = originalInfo as? [AnyHashable: Any] else { throw HEICComposerError.noDepthInPhoto }
        let original = try AVDepthData(fromDictionaryRepresentation: dictionary)
        let replaced = try trueDisparity(from: original, meters: values, width: width, height: height)
        var depthType: NSString?
        guard let depthInfo = replaced.dictionaryRepresentation(forAuxiliaryDataType: &depthType),
              let depthType else { throw HEICComposerError.cannotEncodeDepth }
        CGImageDestinationAddAuxiliaryDataInfo(output, depthType as CFString, depthInfo as CFDictionary)

        guard CGImageDestinationFinalize(output) else { throw HEICComposerError.finalizeFailed(destination) }
        guard let written = CGImageSourceCreateWithURL(destination as CFURL, nil) else {
            throw HEICComposerError.cannotRead(destination)
        }
        try verify(written, expected: values, width: width, height: height)
    }

    /// Photo depth with a correct label: `meters` stored as true disparity (1/m, Float16), keeping ALL of the
    /// original's metadata — camera calibration, accuracy, filtering, version. Used to fix what iOS 26 writes
    /// on iPhone 17 (meters labelled disparity).
    ///
    /// Built by swapping only the raw bytes in the original's dictionary representation:
    /// `AVDepthData.replacingDepthDataMap(with:)` drops the camera calibration and most metadata.
    static func trueDisparity(from original: AVDepthData, meters: [Float], width: Int, height: Int) throws -> AVDepthData {
        precondition(meters.count == width * height, "meters must be width*height")
        let base = original.depthDataType == kCVPixelFormatType_DisparityFloat16
            ? original
            : original.converting(toDepthDataType: kCVPixelFormatType_DisparityFloat16)  // keeps calibration
        var auxiliaryType: NSString?
        guard var dictionary = base.dictionaryRepresentation(forAuxiliaryDataType: &auxiliaryType),
              let description = dictionary[kCGImageAuxiliaryDataInfoDataDescription as String] as? [String: Any],
              let w = description["Width"] as? Int, let h = description["Height"] as? Int,
              let bytesPerRow = description["BytesPerRow"] as? Int,
              w == width, h == height, bytesPerRow >= width * MemoryLayout<Float16>.size else {
            throw HEICComposerError.cannotEncodeDepth
        }
        var data = Data(count: bytesPerRow * height)
        data.withUnsafeMutableBytes { raw in
            for y in 0..<height {
                for x in 0..<width {
                    let m = meters[y * width + x]
                    let disparity: Float16 = m.isFinite && m > 0 ? Float16(1 / m) : .nan
                    raw.storeBytes(of: disparity, toByteOffset: y * bytesPerRow + x * MemoryLayout<Float16>.size,
                                   as: Float16.self)
                }
            }
        }
        dictionary[kCGImageAuxiliaryDataInfoData as String] = data
        return try AVDepthData(fromDictionaryRepresentation: dictionary)
    }

    /// Reads the depth of an encoded HEIC back and checks it against `expected` meters.
    static func verify(data: Data, expected: [Float], width: Int, height: Int) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw HEICComposerError.verificationFailed(String(localized: "nie można odczytać HEIC"))
        }
        try verify(source, expected: expected, width: width, height: height)
    }

    private static func verify(_ source: CGImageSource, expected: [Float], width: Int, height: Int) throws {
        guard let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeDisparity)
                ?? CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeDepth),
              let dictionary = info as? [AnyHashable: Any] else {
            throw HEICComposerError.verificationFailed(String(localized: "brak głębi po zapisie"))
        }
        let written = try AVDepthData(fromDictionaryRepresentation: dictionary)
        guard written.cameraCalibrationData != nil else {
            throw HEICComposerError.verificationFailed(String(localized: "brak kalibracji kamery po zapisie"))
        }
        guard written.depthDataAccuracy == .absolute else {
            throw HEICComposerError.verificationFailed(String(localized: "dokładność inna niż absolute po zapisie"))
        }
        let depth = written.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        guard let actual = PixelBufferAccess.withFloat32(depth.depthDataMap, { values, w, h, stride in
            (w == width && h == height) ? DepthRaw.packed(values, width: w, height: h, rowStride: stride) : nil
        }) ?? nil else {
            throw HEICComposerError.verificationFailed("inne wymiary po zapisie")
        }
        let comparison = DepthComparison.compare(expected: expected, actual: actual)
        guard comparison.isAcceptable else {
            throw HEICComposerError.verificationFailed(String(
                format: String(localized: "mediana różnicy %.1f mm, %.0f%% pikseli > 5 mm"),
                comparison.medianAbsDifference * 1000, comparison.fractionOverTolerance * 100))
        }
    }
}
