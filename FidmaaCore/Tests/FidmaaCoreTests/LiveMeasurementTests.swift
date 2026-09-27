import Testing
@testable import FidmaaCore

@Test func uprightToSensorMatchesKnownPhotoMapping() {
    // IMG_2376: upright 480x640 pixel (253, 209) is depth-grid pixel x = 209, y = 479 - 253.
    let s = UprightMapping.sensor(fromUpright: (x: 253.0 / 480, y: 209.0 / 640))
    #expect(abs(s.x - 209.0 / 640) < 1e-9)
    #expect(abs(s.y - (1 - 253.0 / 480)) < 1e-9)
}

@Test func intrinsicsScaleToDepthGrid() {
    let k = Intrinsics.scaled(fx: 2767.36, fy: 2767.36, cx: 2019.58, cy: 1520.98,
                              reference: Size2D(width: 4032, height: 3024), width: 640, height: 480)
    #expect(abs(k.fx - 439.26) < 0.01)
    #expect(abs(k.cx - 320.57) < 0.01)
    #expect(abs(k.cy - 241.43) < 0.01)
}

@Test func lateralDistanceInFacePlane() {
    let k = Intrinsics(fx: 439, fy: 439, cx: 320, cy: 240)
    let d = FaceGeometry.lateralDistance((u: 100, v: 200), (u: 100, v: 250), depth: 0.42, intrinsics: k)
    #expect(abs(d - 0.047836) < 1e-5)
}

private func profile(_ pattern: String) -> [PixelSample] {
    pattern.map { $0 == "T" ? PixelSample(luma: 0.8, saturation: 0.1) : PixelSample(luma: 0.2, saturation: 0.6) }
}

@Test func incisorEdgesWithBothRowsOfTeeth() {
    // 40 samples: upper teeth 0...7, cavity, lower teeth 32...39
    let p = profile(String(repeating: "T", count: 8) + String(repeating: ".", count: 24) + String(repeating: "T", count: 8))
    let e = IncisorDetector.edges(p)
    #expect(e?.upper == 7)
    #expect(e?.lower == 32)
}

@Test func incisorEdgesNeedBothRows() {
    #expect(IncisorDetector.edges(profile(String(repeating: "T", count: 8) + String(repeating: ".", count: 32))) == nil)
    #expect(IncisorDetector.edges(profile(String(repeating: ".", count: 40))) == nil)
}

@Test func incisorEdgesIgnoreShortRunsAndMiddleHighlights() {
    // 2-px glints at the ends and a bright tongue highlight in the middle are not teeth
    let p = profile("TT" + String(repeating: ".", count: 15) + "TTTTT" + String(repeating: ".", count: 16) + "TT")
    #expect(IncisorDetector.edges(p) == nil)
}

@Test func neckDeepestPointBelowChin() {
    let offsets: [Float] = (0..<11).map { Float($0) * 0.01 }         // 0...100 mm
    let depths: [Float] = [0.30, 0.305, 0.315, 0.325, 0.33, 0.328, 0.32, 0.315, 0.31, 0.30, 0.29]
    #expect(NeckProfile.deepest(offsetsMeters: offsets, depths: depths, chinDepth: 0.30) == 4)
}

@Test func neckSearchStopsAtBackground() {
    let offsets: [Float] = (0..<9).map { Float($0) * 0.01 }
    let depths: [Float] = [0.30, 0.305, 0.315, 0.32, 0.325, 1.6, 1.6, 1.6, 1.6]
    #expect(NeckProfile.deepest(offsetsMeters: offsets, depths: depths, chinDepth: 0.30) == 4)
}

@Test func neckSearchStopsAfterTooManyHoles() {
    let offsets: [Float] = (0..<12).map { Float($0) * 0.01 }
    let depths: [Float] = [0.30, 0.305, .nan, .nan, .nan, .nan, .nan, .nan, 0.34, 0.35, 0.34, 0.33]
    #expect(NeckProfile.deepest(offsetsMeters: offsets, depths: depths, chinDepth: 0.30) == nil)
}

@Test func neckNeedsPointDeeperThanChin() {
    let offsets: [Float] = (0..<6).map { Float($0) * 0.02 }
    let depths: [Float] = [0.30, 0.29, 0.28, 0.28, 0.27, 0.26]
    #expect(NeckProfile.deepest(offsetsMeters: offsets, depths: depths, chinDepth: 0.30) == nil)
}

@Test func peakHoldIgnoresSingleSpike() {
    var hold = PeakHold()
    for v: Float in [30, 31, 90, 32] { _ = hold.add(v) }
    #expect(hold.maximum == 32)
    hold.reset()
    #expect(hold.maximum == nil)
    #expect(hold.add(10) == 10)
}

@Test func uprightMappingForAllRotations() {
    let u = (x: 0.25, y: 0.1)
    let r0 = UprightMapping.sensor(fromUpright: u, rotationDegrees: 0)
    #expect(r0.x == 0.25 && r0.y == 0.1)
    let r90 = UprightMapping.sensor(fromUpright: u, rotationDegrees: 90)
    #expect(abs(r90.x - 0.1) < 1e-12 && abs(r90.y - 0.75) < 1e-12)
    let r180 = UprightMapping.sensor(fromUpright: u, rotationDegrees: 180)
    #expect(abs(r180.x - 0.75) < 1e-12 && abs(r180.y - 0.9) < 1e-12)
    let r270 = UprightMapping.sensor(fromUpright: u, rotationDegrees: 270)
    #expect(abs(r270.x - 0.9) < 1e-12 && abs(r270.y - 0.25) < 1e-12)
    let r450 = UprightMapping.sensor(fromUpright: u, rotationDegrees: 450)
    #expect(abs(r450.x - r90.x) < 1e-12 && abs(r450.y - r90.y) < 1e-12)
}

@Test func screenMappingIdentity() {
    let p = ScreenMapping.screenPoint(sensor: (x: 0.25, y: 0.5), imageSize: Size2D(width: 640, height: 480),
                                      screen: Size2D(width: 640, height: 480), rotationDegrees: 0, mirrored: false)
    #expect(abs(p.x - 160) < 1e-9 && abs(p.y - 240) < 1e-9)
}

@Test func screenMappingRotatedClockwiseAndMirrored() {
    let image = Size2D(width: 640, height: 480), screen = Size2D(width: 480, height: 640)
    // Rotating the image 90° clockwise puts its top-left corner at the screen's top-right.
    let p = ScreenMapping.screenPoint(sensor: (x: 0, y: 0), imageSize: image, screen: screen,
                                      rotationDegrees: 90, mirrored: false)
    #expect(abs(p.x - 480) < 1e-9 && abs(p.y - 0) < 1e-9)
    let m = ScreenMapping.screenPoint(sensor: (x: 0, y: 0), imageSize: image, screen: screen,
                                      rotationDegrees: 90, mirrored: true)
    #expect(abs(m.x - 0) < 1e-9 && abs(m.y - 0) < 1e-9)
}

@Test func screenMappingAspectFillCrops() {
    // 4:3 image filling a tall screen (sideways): scale by height, horizontal overflow is cropped
    let p = ScreenMapping.screenPoint(sensor: (x: 0.5, y: 0.5), imageSize: Size2D(width: 640, height: 480),
                                      screen: Size2D(width: 390, height: 844), rotationDegrees: 90, mirrored: true)
    #expect(abs(p.x - 195) < 1e-9 && abs(p.y - 422) < 1e-9)
}

@Test func incisorEdgesInDimLight() {
    // indoor light: teeth only mid-bright and a bit yellow, cavity dark red
    let tooth = PixelSample(luma: 0.48, saturation: 0.32), cavity = PixelSample(luma: 0.14, saturation: 0.55)
    let p = Array(repeating: tooth, count: 7) + Array(repeating: cavity, count: 26) + Array(repeating: tooth, count: 7)
    let e = IncisorDetector.edges(p)
    #expect(e?.upper == 6)
    #expect(e?.lower == 33)
}

@Test func incisorEdgesNeedContrast() {
    // closed bite / no cavity: everything similar → no reliable edges
    let a = PixelSample(luma: 0.50, saturation: 0.3), b = PixelSample(luma: 0.44, saturation: 0.3)
    let p = Array(repeating: a, count: 10) + Array(repeating: b, count: 20) + Array(repeating: a, count: 10)
    #expect(IncisorDetector.edges(p) == nil)
}

@Test func toothClassificationIsExposedForOverlay() {
    let p = [PixelSample(luma: 0.8, saturation: 0.1), PixelSample(luma: 0.1, saturation: 0.6)]
    #expect(IncisorDetector.classify(p) == [true, false])
}
