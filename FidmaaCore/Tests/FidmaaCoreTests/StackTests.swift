import Foundation
import Testing
@testable import FidmaaCore

@Test func packedDropsRowPadding() {
    let values: [Float] = [1, 2, 99, 3, 4, 99]
    let packed = values.withUnsafeBufferPointer { DepthRaw.packed($0, width: 2, height: 2, rowStride: 3) }
    #expect(packed == [1, 2, 3, 4])
}

@Test func littleEndianDataOfPackedFrames() {
    let data = DepthRaw.littleEndianData(frames: [[1, 2], [3, 4]])
    #expect(data.count == 16)
    #expect(DepthRaw.floats(fromNativeData: data) == [1, 2, 3, 4]) // test host is little-endian
}

@Test func stackStatisticsPerPixel() {
    // 3 pixels, 3 frames
    let frames: [[Float]] = [
        [1.0, .nan, 0.5],
        [3.0, 0.0, .nan],
        [2.0, -1, .nan],
    ]
    let result = DepthStackStatistics.compute(frames: frames, pixelCount: 3)
    #expect(result.median[0] == 2.0)
    #expect(abs(result.std[0] - 0.8164966) < 1e-5)
    #expect(result.count == [3, 0, 1])
    #expect(result.median[1].isNaN)
    #expect(result.std[1].isNaN)
    #expect(result.median[2] == 0.5)
    #expect(result.std[2] == 0)
}

@Test func stackStatisticsEvenCountAndNoFrames() {
    let result = DepthStackStatistics.compute(frames: [[1], [2], [4], [10]], pixelCount: 1)
    #expect(result.median == [3])
    let empty = DepthStackStatistics.compute(frames: [], pixelCount: 2)
    #expect(empty.count == [0, 0])
    #expect(empty.median.allSatisfy { $0.isNaN })
}

@Test func quaternionAngle() {
    let identity = Quaternion(x: 0, y: 0, z: 0, w: 1)
    // 1 degree around z
    let half = 0.5 * Double.pi / 180
    let rotated = Quaternion(x: 0, y: 0, z: sin(half), w: cos(half))
    #expect(abs(MotionAlignment.angleDegrees(identity, rotated) - 1) < 1e-9)
    // q and -q are the same rotation
    let negated = Quaternion(x: 0, y: 0, z: -sin(half), w: -cos(half))
    #expect(abs(MotionAlignment.angleDegrees(rotated, negated)) < 1e-6)
}

@Test func nearestTimestamp() {
    let times = [1.0, 1.01, 1.02, 1.03]
    #expect(MotionAlignment.nearestIndex(in: times, to: 1.014) == 1)
    #expect(MotionAlignment.nearestIndex(in: times, to: 0.5) == 0)
    #expect(MotionAlignment.nearestIndex(in: times, to: 9) == 3)
    #expect(MotionAlignment.nearestIndex(in: [], to: 1) == nil)
}

@Test func frameSelection() {
    #expect(MotionAlignment.selectFrames(angles: [0.1, 0.5, nil, 0.35], threshold: 0.35) == [true, false, true, true])
}

@Test func framesFileEncodesNulls() throws {
    let file = FramesFile(
        referenceFrameIndex: 1,
        frames: [FrameRecord(index: 0, timestamp: 10.0, rotationFromReferenceDegrees: nil,
                             motionTimeOffsetSeconds: nil, used: true)],
        streamCalibration: nil)
    let json = try #require(JSONSerialization.jsonObject(with: FidmaaJSON.encode(file)) as? [String: Any])
    #expect(json["streamCalibration"] is NSNull)
    let frame = try #require((json["frames"] as? [[String: Any]])?.first)
    #expect(frame["rotationFromReference_deg"] is NSNull)
}

@Test func captureMetadataStackSection() throws {
    let stack = StackInfo(requestedFrames: 15, windowSeconds: 0.5, framesCaptured: 15, framesUsed: 12,
                          rotationThresholdDegrees: 0.35, width: 640, height: 480, motionAvailable: true)
    let metadata = CaptureMetadata(
        captureDate: Date(timeIntervalSince1970: 0), deviceModel: "x", systemVersion: "y", depth: nil,
        image: ImageInfo(width: 1, height: 1, exifOrientation: 1, mirrored: false), calibration: nil,
        mattes: MatteFiles(), distanceAtCaptureMeters: nil, stack: stack)
    let data = try metadata.jsonData()
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let s = try #require(json["stack"] as? [String: Any])
    #expect(s["framesUsed"] as? Int == 12)
    #expect(s["requestedFrames"] as? Int == 15)
    #expect(s["medianFile"] as? String == "depth_median.f32")
    #expect(try CaptureMetadata.decode(data) == metadata)
}

@Test func quaternionAngleToleratesNonUnitNorm() {
    // CoreMotion quaternions are not exactly unit length; |q|² = 1 - 1e-7 gave 0.05° against itself.
    let s = (1 - 1e-7).squareRoot()
    let q = Quaternion(x: 0.1 * s, y: 0.2 * s, z: 0.3 * s, w: (1 - 0.14).squareRoot() * s)
    #expect(MotionAlignment.angleDegrees(q, q) < 1e-4)
}
