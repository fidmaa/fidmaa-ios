import Foundation

public enum DepthAccuracyLabel: String, Codable, Sendable {
    case absolute, relative, unknown
}

public struct Size2D: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct Point2D: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct DepthInfo: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var units = "meters"
    public var pixelFormat = "DepthFloat32"
    public var accuracy: DepthAccuracyLabel
    public var quality: String
    public var isFiltered: Bool
    public var originalPixelFormat: String
    public var invalidValue = "NaN or 0 (treat both as invalid)"

    public init(width: Int, height: Int, accuracy: DepthAccuracyLabel, quality: String,
                isFiltered: Bool, originalPixelFormat: String) {
        self.width = width
        self.height = height
        self.accuracy = accuracy
        self.quality = quality
        self.isFiltered = isFiltered
        self.originalPixelFormat = originalPixelFormat
    }
}

public struct ImageInfo: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var exifOrientation: Int
    public var mirrored: Bool

    public init(width: Int, height: Int, exifOrientation: Int, mirrored: Bool) {
        self.width = width
        self.height = height
        self.exifOrientation = exifOrientation
        self.mirrored = mirrored
    }
}

public struct CalibrationInfo: Codable, Equatable, Sendable {
    /// Row-major 3x3, in pixels of `intrinsicMatrixReferenceDimensions`.
    public var intrinsicMatrix: [[Float]]
    public var intrinsicMatrixReferenceDimensions: Size2D
    /// Row-major 3x4 [R|t].
    public var extrinsicMatrix: [[Float]]
    public var pixelSizeMillimeters: Float
    public var lensDistortionCenter: Point2D
    public var lensDistortionLookupTable: [Float]
    public var inverseLensDistortionLookupTable: [Float]

    enum CodingKeys: String, CodingKey {
        case intrinsicMatrix, intrinsicMatrixReferenceDimensions, extrinsicMatrix
        case pixelSizeMillimeters = "pixelSize_mm"
        case lensDistortionCenter, lensDistortionLookupTable, inverseLensDistortionLookupTable
    }

    public init(intrinsicMatrix: [[Float]], intrinsicMatrixReferenceDimensions: Size2D,
                extrinsicMatrix: [[Float]], pixelSizeMillimeters: Float, lensDistortionCenter: Point2D,
                lensDistortionLookupTable: [Float], inverseLensDistortionLookupTable: [Float]) {
        self.intrinsicMatrix = intrinsicMatrix
        self.intrinsicMatrixReferenceDimensions = intrinsicMatrixReferenceDimensions
        self.extrinsicMatrix = extrinsicMatrix
        self.pixelSizeMillimeters = pixelSizeMillimeters
        self.lensDistortionCenter = lensDistortionCenter
        self.lensDistortionLookupTable = lensDistortionLookupTable
        self.inverseLensDistortionLookupTable = inverseLensDistortionLookupTable
    }
}

/// File names of exported mattes; `nil` (written as JSON null) when the camera delivered none.
public struct MatteFiles: Codable, Equatable, Sendable {
    public var portrait: String?
    public var hair: String?
    public var skin: String?
    public var teeth: String?
    public var glasses: String?

    enum CodingKeys: String, CodingKey { case portrait, hair, skin, teeth, glasses }

    public init(portrait: String? = nil, hair: String? = nil, skin: String? = nil,
                teeth: String? = nil, glasses: String? = nil) {
        self.portrait = portrait
        self.hair = hair
        self.skin = skin
        self.teeth = teeth
        self.glasses = glasses
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(portrait, forKey: .portrait)
        try container.encode(hair, forKey: .hair)
        try container.encode(skin, forKey: .skin)
        try container.encode(teeth, forKey: .teeth)
        try container.encode(glasses, forKey: .glasses)
    }
}

/// Contents of `calibration.json`. Optional values are always written, as `null` when missing.
public struct CaptureMetadata: Codable, Equatable, Sendable {
    public var captureDate: Date
    public var deviceModel: String
    public var systemVersion: String
    public var depth: DepthInfo?
    public var image: ImageInfo
    public var calibration: CalibrationInfo?
    public var mattes: MatteFiles
    public var distanceAtCaptureMeters: Float?

    enum CodingKeys: String, CodingKey {
        case captureDate, deviceModel, systemVersion, depth, image, calibration, mattes
        case distanceAtCaptureMeters = "distanceAtCapture_m"
    }

    public init(captureDate: Date, deviceModel: String, systemVersion: String, depth: DepthInfo?,
                image: ImageInfo, calibration: CalibrationInfo?, mattes: MatteFiles,
                distanceAtCaptureMeters: Float?) {
        self.captureDate = captureDate
        self.deviceModel = deviceModel
        self.systemVersion = systemVersion
        self.depth = depth
        self.image = image
        self.calibration = calibration
        self.mattes = mattes
        self.distanceAtCaptureMeters = distanceAtCaptureMeters
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(captureDate, forKey: .captureDate)
        try container.encode(deviceModel, forKey: .deviceModel)
        try container.encode(systemVersion, forKey: .systemVersion)
        try container.encode(depth, forKey: .depth)
        try container.encode(image, forKey: .image)
        try container.encode(calibration, forKey: .calibration)
        try container.encode(mattes, forKey: .mattes)
        try container.encode(distanceAtCaptureMeters, forKey: .distanceAtCaptureMeters)
    }

    private static let positiveInfinity = "Infinity"
    private static let negativeInfinity = "-Infinity"
    private static let nan = "NaN"

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: Self.positiveInfinity, negativeInfinity: Self.negativeInfinity, nan: Self.nan)
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> CaptureMetadata {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: positiveInfinity, negativeInfinity: negativeInfinity, nan: nan)
        return try decoder.decode(CaptureMetadata.self, from: data)
    }
}
