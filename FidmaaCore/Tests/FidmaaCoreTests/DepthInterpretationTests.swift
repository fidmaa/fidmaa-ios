import Foundation
import Testing
@testable import FidmaaCore

@Test func keepsLabelledWhenConsistentWithStream() {
    #expect(DepthInterpretation.choose(photoCenter: 0.37, streamCenter: 0.36) == .asLabelled)
}

@Test func invertsWhenReciprocalMatchesStream() {
    #expect(DepthInterpretation.choose(photoCenter: 2.78, streamCenter: 0.36) == .inverted)
}

@Test func unverifiedWithoutBothMedians() {
    #expect(DepthInterpretation.choose(photoCenter: nil, streamCenter: 0.36) == .unverified)
    #expect(DepthInterpretation.choose(photoCenter: 0.4, streamCenter: nil) == .unverified)
}

@Test func invertKeepsInvalidValues() {
    let result = DepthInterpretation.inverted([2.0, 0, .nan, -1, 4])
    #expect(result[0] == 0.5)
    #expect(result[1] == 0)
    #expect(result[2].isNaN)
    #expect(result[3] == -1)
    #expect(result[4] == 0.25)
}

@Test func depthInfoEncodesInterpretationAndCenters() throws {
    var info = DepthInfo(width: 640, height: 480, accuracy: .absolute, quality: "high",
                         isFiltered: false, originalPixelFormat: "hdis")
    info.interpretation = .inverted
    info.photoCenterMeters = 2.78
    let json = try #require(try JSONSerialization.jsonObject(with: FidmaaJSON.encode(info)) as? [String: Any])
    #expect(json["interpretation"] as? String == "inverted-to-match-stream")
    #expect(json["orientation"] as? String == "sensor")
    #expect(json["streamCenter_m"] is NSNull)
    #expect(json["heicDepth"] is NSNull)
    #expect(try FidmaaJSON.decode(DepthInfo.self, from: FidmaaJSON.encode(info)) == info)
}
