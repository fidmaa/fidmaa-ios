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
        case .cannotRead(let url): "Nie można odczytać \(url.lastPathComponent)"
        case .cannotCreateDestination(let url): "Nie można utworzyć \(url.lastPathComponent)"
        case .noDepthInPhoto: "Zdjęcie nie ma osadzonej głębi"
        case .cannotCreatePixelBuffer: "Nie można utworzyć bufora głębi"
        case .cannotEncodeDepth: "Nie można zakodować głębi"
        case .finalizeFailed(let url): "Nie udało się zapisać \(url.lastPathComponent)"
        case .verificationFailed(let details): "Głębia w zapisanym HEIC nie zgadza się z danymi (\(details))"
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
        let replaced = try original.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
            .replacingDepthDataMap(with: pixelBuffer(values, width: width, height: height))
            .converting(toDepthDataType: kCVPixelFormatType_DisparityFloat16)
        var depthType: NSString?
        guard let depthInfo = replaced.dictionaryRepresentation(forAuxiliaryDataType: &depthType),
              let depthType else { throw HEICComposerError.cannotEncodeDepth }
        CGImageDestinationAddAuxiliaryDataInfo(output, depthType as CFString, depthInfo as CFDictionary)

        guard CGImageDestinationFinalize(output) else { throw HEICComposerError.finalizeFailed(destination) }
        try verify(destination, expected: values, width: width, height: height)
    }

    private static func verify(_ url: URL, expected: [Float], width: Int, height: Int) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeDisparity)
                ?? CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeDepth),
              let dictionary = info as? [AnyHashable: Any] else {
            throw HEICComposerError.verificationFailed("brak głębi po zapisie")
        }
        let depth = try AVDepthData(fromDictionaryRepresentation: dictionary)
            .converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        guard let actual = PixelBufferAccess.withFloat32(depth.depthDataMap, { values, w, h, stride in
            (w == width && h == height) ? DepthRaw.packed(values, width: w, height: h, rowStride: stride) : nil
        }) ?? nil else {
            throw HEICComposerError.verificationFailed("inne wymiary po zapisie")
        }
        let comparison = DepthComparison.compare(expected: expected, actual: actual)
        guard comparison.isAcceptable else {
            throw HEICComposerError.verificationFailed(String(
                format: "mediana różnicy %.1f mm, %.0f%% pikseli > 5 mm",
                comparison.medianAbsDifference * 1000, comparison.fractionOverTolerance * 100))
        }
    }

    private static func pixelBuffer(_ values: [Float], width: Int, height: Int) throws -> CVPixelBuffer {
        precondition(values.count == width * height, "values must be width*height")
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_DepthFloat32, nil, &buffer) == kCVReturnSuccess,
              let buffer else { throw HEICComposerError.cannotCreatePixelBuffer }
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
            throw HEICComposerError.cannotCreatePixelBuffer
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw HEICComposerError.cannotCreatePixelBuffer }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        values.withUnsafeBytes { raw in
            for y in 0..<height {
                memcpy(base + y * bytesPerRow, raw.baseAddress! + y * width * MemoryLayout<Float>.size,
                       width * MemoryLayout<Float>.size)
            }
        }
        return buffer
    }
}
