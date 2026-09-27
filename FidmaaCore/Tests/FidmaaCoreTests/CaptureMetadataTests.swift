import Foundation
import Testing
@testable import FidmaaCore

private func sample(calibration: CalibrationInfo? = nil, distance: Float? = 0.42) -> CaptureMetadata {
    CaptureMetadata(
        captureDate: Date(timeIntervalSince1970: 1_790_000_000),
        deviceModel: "iPhone18,1",
        systemVersion: "26.5.0",
        depth: DepthInfo(width: 640, height: 480, accuracy: .absolute, quality: "high",
                         isFiltered: false, originalPixelFormat: "fdep"),
        image: ImageInfo(width: 4032, height: 3024, exifOrientation: 5, mirrored: true),
        calibration: calibration,
        mattes: MatteFiles(portrait: "portrait.png", hair: "hair.png", skin: nil, teeth: "teeth.png", glasses: nil),
        distanceAtCaptureMeters: distance)
}

private func object(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test func missingValuesAreExplicitNulls() throws {
    let json = try object(sample(calibration: nil, distance: nil).jsonData())
    #expect(json["calibration"] is NSNull)
    #expect(json["distanceAtCapture_m"] is NSNull)
    let mattes = try #require(json["mattes"] as? [String: Any])
    #expect(mattes["skin"] is NSNull)
    #expect(mattes["glasses"] is NSNull)
    #expect(mattes["hair"] as? String == "hair.png")
}

@Test func depthSectionFields() throws {
    let json = try object(sample().jsonData())
    let depth = try #require(json["depth"] as? [String: Any])
    #expect(depth["accuracy"] as? String == "absolute")
    #expect(depth["units"] as? String == "meters")
    #expect(depth["pixelFormat"] as? String == "DepthFloat32")
    #expect(depth["isFiltered"] as? Bool == false)
    #expect(json["captureDate"] as? String == "2026-09-21T14:13:20Z")
}

@Test func calibrationKeysAndRoundTrip() throws {
    let calibration = CalibrationInfo(
        intrinsicMatrix: [[1000, 0, 320], [0, 1000, 240], [0, 0, 1]],
        intrinsicMatrixReferenceDimensions: Size2D(width: 4032, height: 3024),
        extrinsicMatrix: [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0]],
        pixelSizeMillimeters: 0.001,
        lensDistortionCenter: Point2D(x: 2016, y: 1512),
        lensDistortionLookupTable: [0, 0.1],
        inverseLensDistortionLookupTable: [0, -0.1])
    let metadata = sample(calibration: calibration)
    let data = try metadata.jsonData()
    let cal = try #require(try object(data)["calibration"] as? [String: Any])
    #expect(cal["pixelSize_mm"] != nil)
    #expect(try CaptureMetadata.decode(data) == metadata)
}

@Test func nanDistanceDoesNotThrow() throws {
    let json = try object(sample(distance: .nan).jsonData())
    #expect(json["distanceAtCapture_m"] as? String == "NaN")
}
