import Foundation

public struct Quaternion: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double
    public var w: Double
    public init(x: Double, y: Double, z: Double, w: Double) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }
}

public enum MotionAlignment {
    /// Rotation angle between two attitude quaternions, in degrees (q and -q are equal).
    /// Normalizes first: CoreMotion quaternions deviate from unit length enough to matter near 0°.
    public static func angleDegrees(_ a: Quaternion, _ b: Quaternion) -> Double {
        let norms = (a.x * a.x + a.y * a.y + a.z * a.z + a.w * a.w).squareRoot()
            * (b.x * b.x + b.y * b.y + b.z * b.z + b.w * b.w).squareRoot()
        guard norms > 0 else { return .nan }
        let dot = abs(a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w) / norms
        return 2 * acos(min(1, dot)) * 180 / .pi
    }

    /// Index of the timestamp closest to `t` in an ascending array.
    public static func nearestIndex(in timestamps: [Double], to t: Double) -> Int? {
        guard !timestamps.isEmpty else { return nil }
        var low = 0
        var high = timestamps.count - 1
        while low < high {
            let mid = (low + high) / 2
            if timestamps[mid] < t { low = mid + 1 } else { high = mid }
        }
        if low > 0 && abs(timestamps[low - 1] - t) <= abs(timestamps[low] - t) { return low - 1 }
        return low
    }

    /// A frame is used when its rotation from the reference is within `threshold` degrees.
    /// Frames without motion data (`nil`) are used — there is nothing to reject them on.
    public static func selectFrames(angles: [Double?], threshold: Double) -> [Bool] {
        angles.map { angle in angle.map { $0 <= threshold } ?? true }
    }
}
