import Foundation

public extension Point3 {
    func dot(_ o: Point3) -> Float { x * o.x + y * o.y + z * o.z }
}

/// Direction of the thyromental height for a patient sitting upright with the head supported:
/// horizontal, perpendicular to the support — i.e. the camera axis with its vertical component removed.
public enum MeasurementDirection {
    /// `gravity` in device coordinates (CoreMotion: x right, y up, z out of the screen). The front
    /// camera looks along +z. Result is in upright camera coordinates (x right, y down, z forward).
    public static func horizontal(gravity g: (x: Double, y: Double, z: Double)) -> Point3 {
        let n = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
        guard n > 0 else { return Point3(x: 0, y: 0, z: 1) }
        let gx = g.x / n, gy = g.y / n, gz = g.z / n
        // a = (0,0,1); h = a − (a·ĝ)ĝ
        var hx = -gz * gx, hy = -gz * gy, hz = 1 - gz * gz
        let hn = (hx * hx + hy * hy + hz * hz).squareRoot()
        guard hn > 1e-6 else { return Point3(x: 0, y: 0, z: 1) }  // phone flat: no horizontal axis
        hx /= hn; hy /= hn; hz /= hn
        return Point3(x: Float(hx), y: Float(-hy), z: Float(hz))
    }

    /// Camera-space point of the sensor frame → the upright frame (rotated clockwise by `rotationDegrees`).
    public static func uprightCamera(fromSensor p: Point3, rotationDegrees: Int) -> Point3 {
        switch ((rotationDegrees % 360) + 360) % 360 {
        case 90: Point3(x: -p.y, y: p.x, z: p.z)
        case 180: Point3(x: -p.x, y: -p.y, z: p.z)
        case 270: Point3(x: p.y, y: -p.x, z: p.z)
        default: p
        }
    }

    /// Pitch of the camera axis above the horizon, degrees (positive = looking up).
    public static func pitchDegrees(gravity g: (x: Double, y: Double, z: Double)) -> Double {
        let n = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
        guard n > 0 else { return 0 }
        return asin(max(-1, min(1, -g.z / n))) * 180 / .pi
    }
}

/// Neck profile below the chin, `values` = position along the measurement direction (bigger = further
/// back). Finds the submental recess (first back-most point) and, after it, the thyroid cartilage
/// prominence: a local forward bump that is followed by the neck receding again.
public enum ThyromentalProfile {
    public static let recessMinOffset: Float = 0.01
    public static let recessMaxOffset: Float = 0.08
    public static let thyroidMaxOffset: Float = 0.12
    /// The surface must come forward this much after the recess to count as past it.
    public static let recessDrop: Float = 0.0029
    /// …and recede this much after a forward point for that point to be a prominence.
    public static let thyroidRise: Float = 0.0015
    public static let backgroundJump: Float = 0.10
    public static let maxHoles = 5

    public static func analyze(offsetsMeters: [Float], values: [Float]) -> (recess: Int?, thyroid: Int?) {
        precondition(offsetsMeters.count == values.count, "one value per offset")
        var fallbackRecess: Int?
        var recess: Int?
        var runningMax: Int?
        var runningMin: Int?
        var previous: Float?
        var holes = 0
        for (i, offset) in offsetsMeters.enumerated() {
            if offset > thyroidMaxOffset { break }
            let v = values[i]
            guard v.isFinite else {
                holes += 1
                if holes > maxHoles { break }
                continue
            }
            holes = 0
            if let p = previous, abs(v - p) > backgroundJump { break }
            previous = v
            if offset >= recessMinOffset && offset <= recessMaxOffset,
               v > (fallbackRecess.map { values[$0] } ?? -.infinity) {
                fallbackRecess = i
            }
            guard offset >= recessMinOffset else { continue }
            if recess == nil {
                if v > (runningMax.map { values[$0] } ?? -.infinity) { runningMax = i }
                if let m = runningMax, values[m] - v >= recessDrop { recess = m; runningMin = i }
                continue
            }
            if let m = runningMin, v < values[m] { runningMin = i }
            if let m = runningMin, v - values[m] >= thyroidRise {
                return (recess, m)
            }
        }
        return (recess ?? fallbackRecess, nil)
    }
}

/// Median of the values seen during the last `window` seconds — a steady readout for static measures.
public struct RollingMedian: Sendable {
    public let window: Double
    private var samples: [(time: Double, value: Float)] = []

    public init(window: Double) {
        self.window = window
    }

    public mutating func add(_ value: Float, at time: Double) -> Float {
        samples.append((time, value))
        samples.removeAll { $0.time < time - window }
        let sorted = samples.map(\.value).sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    public mutating func reset() {
        samples.removeAll()
    }
}
