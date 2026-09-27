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
    /// Plausibility (values are relative to the chin): the thyroid must lie behind the chin by at least
    /// this much, and protrude from the recess by at most `maxProtrusion` (clothing does more).
    public static let minHeight: Float = 0.02
    public static let maxProtrusion: Float = 0.03

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
                if let r = recess, values[m] >= minHeight, values[r] - values[m] <= maxProtrusion {
                    return (recess, m)
                }
                return (recess, nil)
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

/// Facial midline as a straight axis (principal direction of Vision's median-line points), oriented
/// from the first point (nose bridge) towards the last (chin).
public struct FaceAxis: Sendable {
    public var origin: (x: Double, y: Double)
    public var dir: (x: Double, y: Double)

    public init(origin: (x: Double, y: Double), dir: (x: Double, y: Double)) {
        self.origin = origin
        self.dir = dir
    }

    public static func fit(_ points: [(x: Double, y: Double)]) -> FaceAxis {
        precondition(points.count >= 2, "need at least two points")
        let n = Double(points.count)
        let mx = points.map(\.x).reduce(0, +) / n, my = points.map(\.y).reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for p in points {
            sxx += (p.x - mx) * (p.x - mx); sxy += (p.x - mx) * (p.y - my); syy += (p.y - my) * (p.y - my)
        }
        let angle = 0.5 * atan2(2 * sxy, sxx - syy)   // principal axis
        var d = (x: cos(angle), y: sin(angle))
        let first = points[0], last = points[points.count - 1]
        if (last.x - first.x) * d.x + (last.y - first.y) * d.y < 0 { d = (-d.x, -d.y) }
        // origin: the first point projected onto the axis
        let t = (first.x - mx) * d.x + (first.y - my) * d.y
        return FaceAxis(origin: (mx + t * d.x, my + t * d.y), dir: d)
    }

    public func along(_ p: (x: Double, y: Double)) -> Double {
        (p.x - origin.x) * dir.x + (p.y - origin.y) * dir.y
    }

    public func across(_ p: (x: Double, y: Double)) -> Double {
        -(p.x - origin.x) * dir.y + (p.y - origin.y) * dir.x
    }

    public func point(along s: Double, across l: Double) -> (x: Double, y: Double) {
        (origin.x + dir.x * s - dir.y * l, origin.y + dir.y * s + dir.x * l)
    }
}

/// Anterior point of the chin (pogonion) in the face's own frame: the profile point most in front of
/// the line from the nasion to the menton, so head pitch relative to the camera doesn't matter.
public enum ChinProfile {
    /// `along` = distance along the face axis (m), `depths` = camera depth (m) of the midline profile.
    public static func pogonion(along: [Float], depths: [Float], nasion: (along: Float, depth: Float),
                                menton: (along: Float, depth: Float)) -> Int? {
        precondition(along.count == depths.count, "one depth per sample")
        let span = menton.along - nasion.along
        guard span > 0 else { return nil }
        var best: Int?
        var bestForward: Float = 0
        for i in along.indices where depths[i].isFinite && depths[i] > 0 {
            let lineDepth = nasion.depth + (menton.depth - nasion.depth) * (along[i] - nasion.along) / span
            let forward = lineDepth - depths[i]   // > 0: in front of the face line
            if forward > bestForward { bestForward = forward; best = i }
        }
        return best
    }
}

/// Center of the "plateau" of near-best candidates: on a flat profile the single best sample jumps with
/// noise, the middle of all samples within `tolerance` of the best does not.
public enum Plateau {
    /// Index nearest to the mean index of all finite scores within `tolerance` of the maximum.
    public static func center(scores: [Float], tolerance: Float) -> Int? {
        guard let best = scores.filter(\.isFinite).max() else { return nil }
        let members = scores.indices.filter { scores[$0].isFinite && scores[$0] >= best - tolerance }
        let mean = Double(members.reduce(0, +)) / Double(members.count)
        return Int(mean.rounded())
    }
}

/// True once the positions seen in the last `window` seconds stay within `maxSpread` (and there are at
/// least `minSamples` of them) — results are shown only when the measurement has settled.
public struct StabilityGate: Sendable {
    public let window: Double
    public let maxSpread: Float
    public let minSamples: Int
    private var samples: [(time: Double, value: Float)] = []

    public init(window: Double, maxSpread: Float, minSamples: Int) {
        self.window = window
        self.maxSpread = maxSpread
        self.minSamples = minSamples
    }

    public mutating func add(_ value: Float, at time: Double) -> Bool {
        samples.append((time, value))
        samples.removeAll { $0.time < time - window }
        guard samples.count >= minSamples,
              let lo = samples.map(\.value).min(), let hi = samples.map(\.value).max() else { return false }
        return hi - lo <= maxSpread
    }

    public mutating func reset() {
        samples.removeAll()
    }
}
