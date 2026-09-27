import Testing
@testable import FidmaaCore

@Test func horizontalDirectionForUprightPhoneIsCameraAxis() {
    let h = MeasurementDirection.horizontal(gravity: (x: 0, y: -1, z: 0))
    #expect(abs(h.x) < 1e-6 && abs(h.y) < 1e-6 && abs(h.z - 1) < 1e-6)
}

@Test func horizontalDirectionRemovesPitch() {
    // phone pitched: gravity has a component along the camera axis
    let h = MeasurementDirection.horizontal(gravity: (x: 0, y: -0.8, z: -0.6))
    // device (0, -0.6, 0.8) → upright camera (x, -y, z)
    #expect(abs(h.x) < 1e-6 && abs(h.y - 0.6) < 1e-6 && abs(h.z - 0.8) < 1e-6)
}

@Test func uprightCameraRotation() {
    let p = Point3(x: 0.01, y: 0.02, z: 0.4)
    let r90 = MeasurementDirection.uprightCamera(fromSensor: p, rotationDegrees: 90)
    #expect(abs(r90.x - -0.02) < 1e-7 && abs(r90.y - 0.01) < 1e-7 && r90.z == 0.4)
    let r0 = MeasurementDirection.uprightCamera(fromSensor: p, rotationDegrees: 0)
    #expect(r0 == p)
    let r180 = MeasurementDirection.uprightCamera(fromSensor: p, rotationDegrees: 180)
    #expect(abs(r180.x - -0.01) < 1e-7 && abs(r180.y - -0.02) < 1e-7)
    let r270 = MeasurementDirection.uprightCamera(fromSensor: p, rotationDegrees: 270)
    #expect(abs(r270.x - 0.02) < 1e-7 && abs(r270.y - -0.01) < 1e-7)
}

// Profile values = projection on the measurement direction (bigger = further back), per 5 mm step below the chin.
private let steps: [Float] = (0..<25).map { Float($0) * 0.005 }

@Test func thyroidFoundAfterRecess() {
    // chin 0, recess at 30 mm, thyroid bump at 55 mm, then the neck recedes again
    let v: [Float] = [0, 0.005, 0.012, 0.018, 0.022, 0.024, 0.025, 0.024, 0.022, 0.020, 0.019,
                      0.018, 0.018, 0.019, 0.020, 0.022, 0.024, 0.026, 0.028, 0.030, 0.031, 0.032, 0.033, 0.034, 0.035]
    // realistic magnitudes (recess ~62 mm behind the chin): scale the shape by 2.5
    let r = ThyromentalProfile.analyze(offsetsMeters: steps, values: v.map { $0 * 2.5 })
    #expect(r.recess == 6)
    #expect(r.thyroid == 11)
}

@Test func noThyroidFallsBackToRecess() {
    // smooth neck: recess, then only recedes (no bump)
    let v: [Float] = [0, 0.006, 0.012, 0.017, 0.021, 0.024, 0.026, 0.027, 0.028, 0.029, 0.030,
                      0.031, 0.032, 0.033, 0.034, 0.035, 0.036, 0.037, 0.038, 0.039, 0.040, 0.041, 0.042, 0.043, 0.044]
    let r = ThyromentalProfile.analyze(offsetsMeters: steps, values: v)
    #expect(r.thyroid == nil)
    #expect(r.recess != nil)
}

@Test func chestComingForwardIsNotThyroid() {
    // after the recess the surface only comes forward (chest) without receding again
    let v: [Float] = [0, 0.008, 0.015, 0.020, 0.023, 0.024, 0.023, 0.021, 0.018, 0.015, 0.012,
                      0.009, 0.006, 0.003, 0.0, -0.003, -0.006, -0.009, -0.012, -0.015, -0.018, -0.021, -0.024, -0.027, -0.03]
    let r = ThyromentalProfile.analyze(offsetsMeters: steps, values: v)
    #expect(r.thyroid == nil)
}

@Test func profileStopsAtBackgroundAndHoles() {
    var v: [Float] = Array(repeating: 0.02, count: 25)
    v[0] = 0; v[1] = 0.01; v[2] = 0.018
    for i in 3..<25 { v[i] = 1.5 }   // background right after
    let r = ThyromentalProfile.analyze(offsetsMeters: steps, values: v)
    #expect(r.thyroid == nil)
}

@Test func rollingMedianOverTimeWindow() {
    var m = RollingMedian(window: 2.0)
    #expect(m.add(50, at: 0) == 50)
    #expect(m.add(52, at: 0.5) == 51)
    #expect(m.add(90, at: 1.0) == 52)        // single outlier doesn't move it much
    #expect(m.add(60, at: 3.1) == 60)        // older values fell out of the 2 s window
    m.reset()
    #expect(m.add(10, at: 5) == 10)
}

@Test func faceAxisFollowsMedianLineNotNostrils() {
    // IMG diag 20260928-000933: median line is vertical at x≈265, from nose bridge to chin
    let pts: [(x: Double, y: Double)] = [(266, 255), (266, 269), (265, 282), (264, 296), (265, 315), (265, 337),
                                         (265, 344), (265, 346), (264, 353), (262, 418)]
    let axis = FaceAxis.fit(pts)
    #expect(abs(axis.dir.x) < 0.05 && axis.dir.y > 0.99)   // points down, towards the chin
    #expect(abs(axis.along((x: 262, y: 418)) - (418 - 255)) < 3)
}

@Test func pogonionIsMostAnteriorRelativeToFaceLine() {
    // profile along the face axis: (along m, depth m). Nasion at 0 / 0.36, menton at 0.12 / 0.37.
    // Lower chin bulges 6 mm in front of the nasion–menton line at 0.10 m; the lower lip (0.07) is excluded.
    let along: [Float] = [0.080, 0.085, 0.090, 0.095, 0.100, 0.105, 0.110, 0.115, 0.120]
    let depth: [Float] = [0.362, 0.364, 0.363, 0.360, 0.359, 0.361, 0.364, 0.367, 0.370]
    let i = ChinProfile.pogonion(along: along, depths: depth, nasion: (along: 0, depth: 0.36), menton: (along: 0.12, depth: 0.37))
    #expect(i == 4)
}

@Test func pogonionIgnoresHolesAndNeedsForwardPoint() {
    let along: [Float] = [0.09, 0.10, 0.11]
    #expect(ChinProfile.pogonion(along: along, depths: [.nan, .nan, .nan], nasion: (along: 0, depth: 0.36),
                                 menton: (along: 0.12, depth: 0.37)) == nil)
    // everything behind the line → no prominence
    #expect(ChinProfile.pogonion(along: along, depths: [0.40, 0.41, 0.42], nasion: (along: 0, depth: 0.36),
                                 menton: (along: 0.12, depth: 0.37)) == nil)
}

@Test func jacketCollarIsNotThyroid() {
    // real profile (diag 20260928-000941, mm every 5 px ≈ 3.8 mm): recess ~62 mm, then the jacket collar
    // comes forward to ~0 mm (TMHT −2 mm would be nonsense)
    let mm: [Float] = [14, 28, 57, 61, 62, 59, 57, 53, 47, 37, 35, 33, 26, 18, 13, 13, 11, 7, 6, 3, 0, -2, -1, 0, 2, 3, 2, 0, 2, 4, 4, 3]
    let off = mm.indices.map { Float($0) * 0.0038 }
    let r = ThyromentalProfile.analyze(offsetsMeters: off, values: mm.map { $0 / 1000 })
    #expect(r.thyroid == nil)
    #expect(r.recess == 4)
}

@Test func realThyroidProfileAccepted() {
    // diag 20260928-000933: recess ~70 mm, thyroid bump back to ~61–63 mm, then recedes
    let mm: [Float] = [8, 11, 20, 25, 37, 60, 68, 69, 69, 69, 70, 70, 68, 66, 66, 62, 61, 56, 54, 49, 43, 41, 37]
    let off = mm.indices.map { Float($0) * 0.004 }
    let r = ThyromentalProfile.analyze(offsetsMeters: off, values: mm.map { $0 / 1000 })
    // this frontal profile keeps coming forward (collar) — no receding after a bump → no thyroid
    #expect(r.thyroid == nil)
}

@Test func plateauCenterOfNearlyEqualCandidates() {
    // flat chin: three samples within 1 mm of the best → the middle of them, not the noisy winner
    let scores: [Float] = [0.001, 0.0079, 0.0081, 0.0080, 0.004]
    #expect(Plateau.center(scores: scores, tolerance: 0.001) == 2)
    let skewed: [Float] = [0.0080, 0.0085, 0.0079, 0.0020, 0.0084]
    #expect(Plateau.center(scores: skewed, tolerance: 0.001) == 2)   // mean of 0,1,2,4 ≈ 1.75 → 2
    #expect(Plateau.center(scores: [.nan, .nan], tolerance: 0.001) == nil)
}

@Test func stabilityGateNeedsSteadyPositions() {
    var gate = StabilityGate(window: 1.0, maxSpread: 0.003, minSamples: 5)
    for i in 0..<4 {
        let early = gate.add(0.050 + Float(i) * 0.0005, at: Double(i) * 0.1)
        #expect(!early)                                  // too few samples yet
    }
    let steady = gate.add(0.051, at: 0.4)                // 5 samples, spread 1.5 mm
    #expect(steady)
    let jumped = gate.add(0.060, at: 0.5)                // jump of 10 mm
    #expect(!jumped)
    gate.reset()
    let afterReset = gate.add(0.05, at: 0.6)
    #expect(!afterReset)
}

@Test func profileAverageAlignsByOffsetAndIgnoresHoles() {
    var avg = ProfileAverage(capacity: 3)
    avg.add([0: 1, 1: 2, 2: .nan])
    avg.add([0: 3, 1: 4, 2: 6])
    #expect(avg.mean(at: 0) == 2)
    #expect(avg.mean(at: 1) == 3)
    #expect(avg.mean(at: 2) == nil)          // valid in only 1 of 2 profiles: needs more than half
    avg.add([0: 5])
    avg.add([0: 7])                           // capacity 3 → the first profile drops out
    #expect(avg.mean(at: 0) == 5)
    #expect(avg.count == 3)
    avg.reset()
    #expect(avg.mean(at: 0) == nil)
}
