/// Checks that a depth map read back from a file matches what was written.
public struct DepthComparison: Sendable {
    /// Pixels valid (finite, > 0) in both maps.
    public let validPairs: Int
    public let medianAbsDifference: Float
    /// Fraction of valid pairs differing by more than `tolerance` meters.
    public let fractionOverTolerance: Float

    public static let tolerance: Float = 0.005
    public static let maxFractionOverTolerance: Float = 0.01

    public var isAcceptable: Bool {
        validPairs > 0 && medianAbsDifference <= Self.tolerance / 5
            && fractionOverTolerance <= Self.maxFractionOverTolerance
    }

    public static func compare(expected: [Float], actual: [Float]) -> DepthComparison {
        guard expected.count == actual.count else {
            return DepthComparison(validPairs: 0, medianAbsDifference: .nan, fractionOverTolerance: 1)
        }
        var diffs: [Float] = []
        for (e, a) in zip(expected, actual) where e.isFinite && e > 0 && a.isFinite && a > 0 {
            diffs.append(abs(e - a))
        }
        guard !diffs.isEmpty else {
            return DepthComparison(validPairs: 0, medianAbsDifference: .nan, fractionOverTolerance: 1)
        }
        diffs.sort()
        let over = diffs.reduce(0) { $0 + ($1 > tolerance ? 1 : 0) }
        return DepthComparison(validPairs: diffs.count, medianAbsDifference: diffs[diffs.count / 2],
                               fractionOverTolerance: Float(over) / Float(diffs.count))
    }
}
