import Foundation

/// Summary of the multi-frame depth stack, stored in `calibration.json`.
public struct StackInfo: Codable, Equatable, Sendable {
    /// Averaging setting chosen in the app (1×, 5×, 10×).
    public var requestedFrames: Int
    /// Time between the first and last frame of the stack.
    public var windowSeconds: Double
    public var framesCaptured: Int
    public var framesUsed: Int
    public var rotationThresholdDegrees: Double
    public var width: Int
    public var height: Int
    public var motionAvailable: Bool
    public var stackFile = "depth_stack.f32"
    public var medianFile = "depth_median.f32"
    public var stdFile = "depth_std.f32"
    public var countFile = "depth_count.u8"
    public var framesFile = "frames.json"

    public init(requestedFrames: Int, windowSeconds: Double, framesCaptured: Int, framesUsed: Int, rotationThresholdDegrees: Double,
                width: Int, height: Int, motionAvailable: Bool) {
        self.requestedFrames = requestedFrames
        self.windowSeconds = windowSeconds
        self.framesCaptured = framesCaptured
        self.framesUsed = framesUsed
        self.rotationThresholdDegrees = rotationThresholdDegrees
        self.width = width
        self.height = height
        self.motionAvailable = motionAvailable
    }
}

public struct FrameRecord: Codable, Equatable, Sendable {
    public var index: Int
    /// Capture session host-clock time, seconds.
    public var timestamp: Double
    public var rotationFromReferenceDegrees: Double?
    /// |motion sample time − frame time|; nil when no motion sample was found.
    public var motionTimeOffsetSeconds: Double?
    public var used: Bool

    enum CodingKeys: String, CodingKey {
        case index, timestamp, used
        case rotationFromReferenceDegrees = "rotationFromReference_deg"
        case motionTimeOffsetSeconds = "motionTimeOffset_s"
    }

    public init(index: Int, timestamp: Double, rotationFromReferenceDegrees: Double?,
                motionTimeOffsetSeconds: Double?, used: Bool) {
        self.index = index
        self.timestamp = timestamp
        self.rotationFromReferenceDegrees = rotationFromReferenceDegrees
        self.motionTimeOffsetSeconds = motionTimeOffsetSeconds
        self.used = used
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(index, forKey: .index)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(rotationFromReferenceDegrees, forKey: .rotationFromReferenceDegrees)
        try container.encode(motionTimeOffsetSeconds, forKey: .motionTimeOffsetSeconds)
        try container.encode(used, forKey: .used)
    }
}

/// Contents of `frames.json`.
public struct FramesFile: Codable, Equatable, Sendable {
    public var referenceFrameIndex: Int
    public var frames: [FrameRecord]
    /// Calibration attached to the streamed depth (to compare with the photo's).
    public var streamCalibration: CalibrationInfo?

    public init(referenceFrameIndex: Int, frames: [FrameRecord], streamCalibration: CalibrationInfo?) {
        self.referenceFrameIndex = referenceFrameIndex
        self.frames = frames
        self.streamCalibration = streamCalibration
    }

    enum CodingKeys: String, CodingKey { case referenceFrameIndex, frames, streamCalibration }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(referenceFrameIndex, forKey: .referenceFrameIndex)
        try container.encode(frames, forKey: .frames)
        try container.encode(streamCalibration, forKey: .streamCalibration)
    }
}

/// Shared JSON settings for all exported files.
public enum FidmaaJSON {
    static let positiveInfinity = "Infinity"
    static let negativeInfinity = "-Infinity"
    static let nan = "NaN"

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: positiveInfinity, negativeInfinity: negativeInfinity, nan: nan)
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: positiveInfinity, negativeInfinity: negativeInfinity, nan: nan)
        return try decoder.decode(type, from: data)
    }
}
