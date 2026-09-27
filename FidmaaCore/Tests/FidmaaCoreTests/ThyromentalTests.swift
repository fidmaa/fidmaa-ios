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
    // chin 0, recess +25 mm at 30 mm, thyroid bump back to +18 mm at 70 mm, then neck recedes again
    let v: [Float] = [0, 0.005, 0.012, 0.018, 0.022, 0.024, 0.025, 0.024, 0.022, 0.020, 0.019,
                      0.018, 0.018, 0.019, 0.020, 0.022, 0.024, 0.026, 0.028, 0.030, 0.031, 0.032, 0.033, 0.034, 0.035]
    let r = ThyromentalProfile.analyze(offsetsMeters: steps, values: v)
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
