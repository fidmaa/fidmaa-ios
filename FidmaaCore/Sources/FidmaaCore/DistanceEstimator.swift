/// Result of checking how far the subject is from the TrueDepth camera.
public enum DistanceStatus: Equatable, Sendable {
    case noData
    case tooClose(meters: Float)
    case tooFar(meters: Float)
    case ok(meters: Float)

    public var message: String {
        switch self {
        case .noData: "Brak danych głębi"
        case .tooClose: "Odsuń się"
        case .tooFar: "Przybliż się"
        case .ok(let meters): "OK — odległość \(Int((meters * 100).rounded())) cm"
        }
    }
}

public enum DistanceEstimator {
    public static let minDistance: Float = 0.25
    public static let maxDistance: Float = 0.70
    /// Fraction of width and height used for the central measurement window.
    public static let centerFraction = 0.3

    /// Median of valid (finite, > 0) depth values in the central window.
    /// `rowStride` is the row length in elements, including any padding.
    public static func medianCenterDepth(_ values: UnsafeBufferPointer<Float>,
                                         width: Int, height: Int, rowStride: Int) -> Float? {
        guard width > 0, height > 0, rowStride >= width,
              values.count >= rowStride * (height - 1) + width else { return nil }
        let windowWidth = max(1, Int(Double(width) * centerFraction))
        let windowHeight = max(1, Int(Double(height) * centerFraction))
        let x0 = (width - windowWidth) / 2
        let y0 = (height - windowHeight) / 2
        var valid: [Float] = []
        valid.reserveCapacity(windowWidth * windowHeight)
        for y in y0..<(y0 + windowHeight) {
            let row = y * rowStride
            for x in x0..<(x0 + windowWidth) {
                let value = values[row + x]
                if value.isFinite && value > 0 { valid.append(value) }
            }
        }
        guard !valid.isEmpty else { return nil }
        valid.sort()
        let mid = valid.count / 2
        return valid.count % 2 == 0 ? (valid[mid - 1] + valid[mid]) / 2 : valid[mid]
    }

    public static func status(forMedian median: Float?) -> DistanceStatus {
        guard let median else { return .noData }
        if median < minDistance { return .tooClose(meters: median) }
        if median > maxDistance { return .tooFar(meters: median) }
        return .ok(meters: median)
    }
}
