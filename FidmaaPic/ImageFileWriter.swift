import CoreGraphics
import CoreVideo
import FidmaaCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageFileWriterError: LocalizedError {
    case unexpectedPixelFormat(expected: String, actual: String)
    case noBaseAddress
    case imageCreationFailed
    case destinationCreationFailed(URL)
    case finalizeFailed(URL)

    var errorDescription: String? {
        switch self {
        case let .unexpectedPixelFormat(expected, actual): String(localized: "Nieoczekiwany format bufora: \(actual), oczekiwano \(expected)")
        case .noBaseAddress: String(localized: "Brak dostępu do danych bufora")
        case .imageCreationFailed: String(localized: "Nie udało się utworzyć obrazu")
        case .destinationCreationFailed(let url): String(localized: "Nie można utworzyć pliku \(url.lastPathComponent)")
        case .finalizeFailed(let url): String(localized: "Nie udało się zapisać \(url.lastPathComponent)")
        }
    }
}

enum ImageFileWriter {
    /// Single-channel 32-bit float TIFF, values unchanged (meters for depth).
    static func writeFloat32TIFF(_ buffer: CVPixelBuffer, to url: URL) throws {
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue
            | CGBitmapInfo.floatComponents.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
        try write(buffer, expectedFormat: kCVPixelFormatType_DepthFloat32, bitsPerComponent: 32,
                  bitmapInfo: info, type: .tiff, to: url)
    }

    /// Single-channel 32-bit float TIFF from packed values (row-major, no padding).
    static func writeFloat32TIFF(values: [Float], width: Int, height: Int, to url: URL) throws {
        precondition(values.count == width * height, "values must be width*height")
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue
            | CGBitmapInfo.floatComponents.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
        let data = values.withUnsafeBytes { Data($0) }
        try write(data: data, width: width, height: height, bytesPerRow: width * MemoryLayout<Float>.size,
                  bitsPerComponent: 32, bitmapInfo: info, type: .tiff, to: url)
    }

    /// 8-bit grayscale PNG (mattes: 0 = background, 255 = region).
    static func writeGray8PNG(_ buffer: CVPixelBuffer, to url: URL) throws {
        try write(buffer, expectedFormat: kCVPixelFormatType_OneComponent8, bitsPerComponent: 8,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), type: .png, to: url)
    }

    private static func write(_ buffer: CVPixelBuffer, expectedFormat: OSType, bitsPerComponent: Int,
                              bitmapInfo: CGBitmapInfo, type: UTType, to url: URL) throws {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == expectedFormat else {
            throw ImageFileWriterError.unexpectedPixelFormat(expected: FourCC.string(expectedFormat),
                                                             actual: FourCC.string(format))
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw ImageFileWriterError.noBaseAddress }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let data = Data(bytes: base, count: bytesPerRow * height)
        try write(data: data, width: width, height: height, bytesPerRow: bytesPerRow,
                  bitsPerComponent: bitsPerComponent, bitmapInfo: bitmapInfo, type: type, to: url)
    }

    private static func write(data: Data, width: Int, height: Int, bytesPerRow: Int, bitsPerComponent: Int,
                              bitmapInfo: CGBitmapInfo, type: UTType, to url: URL) throws {
        guard let provider = CGDataProvider(data: data as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.linearGray),
              let image = CGImage(width: width, height: height,
                                  bitsPerComponent: bitsPerComponent, bitsPerPixel: bitsPerComponent,
                                  bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo,
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent)
        else { throw ImageFileWriterError.imageCreationFailed }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        else { throw ImageFileWriterError.destinationCreationFailed(url) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ImageFileWriterError.finalizeFailed(url) }
    }
}
