/// How the photo's depth map was interpreted.
///
/// On iPhone 17 (iOS 26.3) the photo depth converted to DepthFloat32 came out as the reciprocal of
/// the streamed depth (face 2.78 instead of 0.36 m). The streamed depth is checked against the live
/// distance and is trusted; the photo map is flipped only when its reciprocal agrees with the stream.
public enum DepthInterpretation: String, Codable, Sendable {
    case asLabelled = "as-labelled"
    case inverted = "inverted-to-match-stream"
    case unverified

    public static func choose(photoCenter: Float?, streamCenter: Float?) -> DepthInterpretation {
        guard let photo = photoCenter, let stream = streamCenter, photo > 0, stream > 0 else { return .unverified }
        return abs(photo - stream) <= abs(1 / photo - stream) ? .asLabelled : .inverted
    }

    /// 1/x for valid values (finite, > 0); invalid values unchanged.
    public static func inverted(_ values: [Float]) -> [Float] {
        values.map { $0.isFinite && $0 > 0 ? 1 / $0 : $0 }
    }
}
