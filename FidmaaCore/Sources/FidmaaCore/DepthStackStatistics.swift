public struct DepthStackResult: Sendable {
    /// Per-pixel median of valid values; NaN where no frame had a valid value.
    public let median: [Float]
    /// Per-pixel population standard deviation; NaN where no valid value.
    public let std: [Float]
    /// Number of valid values per pixel (saturates at 255).
    public let count: [UInt8]
}

public enum DepthStackStatistics {
    /// `frames` are packed (no padding), each with `pixelCount` values.
    /// Valid = finite and > 0, as for single-frame depth.
    public static func compute(frames: [[Float]], pixelCount: Int) -> DepthStackResult {
        precondition(frames.allSatisfy { $0.count == pixelCount }, "all frames must have pixelCount values")
        var median = [Float](repeating: .nan, count: pixelCount)
        var std = [Float](repeating: .nan, count: pixelCount)
        var count = [UInt8](repeating: 0, count: pixelCount)
        var samples = [Float]()
        samples.reserveCapacity(frames.count)
        for pixel in 0..<pixelCount {
            samples.removeAll(keepingCapacity: true)
            for frame in frames {
                let value = frame[pixel]
                if value.isFinite && value > 0 { samples.append(value) }
            }
            count[pixel] = UInt8(min(samples.count, Int(UInt8.max)))
            guard !samples.isEmpty else { continue }
            samples.sort()
            let mid = samples.count / 2
            median[pixel] = samples.count % 2 == 0 ? (samples[mid - 1] + samples[mid]) / 2 : samples[mid]
            let mean = samples.reduce(0, +) / Float(samples.count)
            let variance = samples.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(samples.count)
            std[pixel] = variance.squareRoot()
        }
        return DepthStackResult(median: median, std: std, count: count)
    }
}
