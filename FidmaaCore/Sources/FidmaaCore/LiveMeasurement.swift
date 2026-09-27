/// Pinhole intrinsics in pixels of the depth grid.
public struct Intrinsics: Equatable, Sendable {
    public var fx: Float
    public var fy: Float
    public var cx: Float
    public var cy: Float

    public init(fx: Float, fy: Float, cx: Float, cy: Float) {
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
    }

    /// Intrinsics given for `reference` dimensions, rescaled to a `width`×`height` grid.
    public static func scaled(fx: Float, fy: Float, cx: Float, cy: Float, reference: Size2D,
                              width: Int, height: Int) -> Intrinsics {
        let sx = Float(Double(width) / reference.width)
        let sy = Float(Double(height) / reference.height)
        return Intrinsics(fx: fx * sx, fy: fy * sy, cx: cx * sx, cy: cy * sy)
    }
}

/// Front camera held upright: frames are in sensor orientation and are shown rotated 90° clockwise
/// (EXIF 6, Vision `.right`). Coordinates are normalized with a top-left origin.
public enum UprightMapping {
    public static func sensor(fromUpright p: (x: Double, y: Double)) -> (x: Double, y: Double) {
        (x: p.y, y: 1 - p.x)
    }
}

public enum FaceGeometry {
    /// Distance between two depth-grid pixels measured in the plane at `depth` (meters).
    /// Used for lip/teeth distances: sampling depth exactly at an opening's edge is unreliable.
    public static func lateralDistance(_ a: (u: Float, v: Float), _ b: (u: Float, v: Float),
                                       depth: Float, intrinsics k: Intrinsics) -> Float {
        let dx = (a.u - b.u) / k.fx
        let dy = (a.v - b.v) / k.fy
        return (dx * dx + dy * dy).squareRoot() * depth
    }
}

public struct PixelSample: Equatable, Sendable {
    /// 0...1
    public var luma: Float
    /// 0...1 (HSV saturation)
    public var saturation: Float

    public init(luma: Float, saturation: Float) {
        self.luma = luma
        self.saturation = saturation
    }
}

/// Finds incisal edges on a pixel profile running from the upper inner lip (index 0) to the lower
/// inner lip (last index): a tooth is bright and unsaturated.
public enum IncisorDetector {
    public static let minLuma: Float = 0.55
    public static let maxSaturation: Float = 0.35
    public static let minRun = 3
    /// Teeth must touch the outer 40% of the profile at their lip.
    public static let band = 0.4

    public static func edges(_ profile: [PixelSample]) -> (upper: Int, lower: Int)? {
        let n = profile.count
        guard n >= 2 * minRun else { return nil }
        var runs: [Range<Int>] = []
        var start: Int?
        for (i, s) in profile.enumerated() {
            let tooth = s.luma > minLuma && s.saturation < maxSaturation
            if tooth, start == nil { start = i }
            if !tooth, let st = start { runs.append(st..<i); start = nil }
        }
        if let st = start { runs.append(st..<n) }
        runs = runs.filter { $0.count >= minRun }
        let bandLength = Int(Double(n) * band)
        guard let upper = runs.first(where: { $0.lowerBound < bandLength }),
              let lower = runs.last(where: { $0.upperBound > n - bandLength }),
              upper != lower, upper.upperBound <= lower.lowerBound else { return nil }
        return (upper.upperBound - 1, lower.lowerBound)
    }
}

/// Deepest point of the submental/neck profile below the chin.
public enum NeckProfile {
    public static let minOffset: Float = 0.02
    public static let maxOffset: Float = 0.08
    public static let backgroundJump: Float = 0.10
    public static let maxHoles = 5

    /// `offsetsMeters` ascending distance below the chin; returns the index of the deepest valid sample
    /// in [minOffset, maxOffset] that lies behind the chin, stopping at background or long gaps.
    public static func deepest(offsetsMeters: [Float], depths: [Float], chinDepth: Float) -> Int? {
        precondition(offsetsMeters.count == depths.count, "one depth per offset")
        var best: Int?
        var previous: Float?
        var holes = 0
        for (i, offset) in offsetsMeters.enumerated() {
            if offset > maxOffset { break }
            let d = depths[i]
            guard d.isFinite && d > 0 else {
                holes += 1
                if holes > maxHoles { break }
                continue
            }
            holes = 0
            if let p = previous, abs(d - p) > backgroundJump { break }
            previous = d
            if offset >= minOffset && d > chinDepth && d > (best.map { depths[$0] } ?? -.infinity) {
                best = i
            }
        }
        return best
    }
}

/// Peak hold fed with the median of the last three values, so one bad frame can't set the maximum.
public struct PeakHold: Sendable {
    public private(set) var maximum: Float?
    private var recent: [Float] = []

    public init() {}

    /// Adds a measurement; returns the smoothed current value.
    public mutating func add(_ value: Float) -> Float {
        recent.append(value)
        if recent.count > 3 { recent.removeFirst() }
        let sorted = recent.sorted()
        let mid = sorted.count / 2
        let smoothed = sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
        maximum = max(maximum ?? smoothed, smoothed)
        return smoothed
    }

    public mutating func reset() {
        maximum = nil
        recent.removeAll()
    }
}
