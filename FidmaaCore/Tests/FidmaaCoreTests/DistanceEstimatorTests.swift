import Testing
@testable import FidmaaCore

/// Builds a width×height grid (with optional row padding) filled with `fill`,
/// then applies `set` for explicit (x, y) values.
private func grid(width: Int, height: Int, rowStride: Int? = nil, fill: Float,
                  padding: Float = 99, set: [(Int, Int, Float)] = []) -> [Float] {
    let stride = rowStride ?? width
    var values = [Float](repeating: padding, count: stride * height)
    for y in 0..<height { for x in 0..<width { values[y * stride + x] = fill } }
    for (x, y, v) in set { values[y * stride + x] = v }
    return values
}

private func median(_ values: [Float], width: Int, height: Int, rowStride: Int? = nil) -> Float? {
    values.withUnsafeBufferPointer {
        DistanceEstimator.medianCenterDepth($0, width: width, height: height, rowStride: rowStride ?? width)
    }
}

private func centerSet(_ values: [Float]) -> [(Int, Int, Float)] {
    values.enumerated().map { (3 + $0.offset % 3, 3 + $0.offset / 3, $0.element) }
}

@Test func uniformDepthGivesThatDepth() {
    #expect(median(grid(width: 10, height: 10, fill: 0.4), width: 10, height: 10) == 0.4)
}

@Test func onlyCenterRegionCounts() {
    // 10x10, center 30% = 3x3 at x,y in 3...5
    let values = grid(width: 10, height: 10, fill: 9, set: centerSet(Array(repeating: 0.5, count: 9)))
    #expect(median(values, width: 10, height: 10) == 0.5)
}

@Test func invalidValuesAreIgnored() {
    let values = grid(width: 10, height: 10, fill: 9,
                      set: centerSet([.nan, 0, 0.3, 0.4, 0.5, 0.6, -1, .infinity, 0.7]))
    #expect(median(values, width: 10, height: 10) == 0.5)
}

@Test func evenCountAveragesMiddlePair() {
    let values = grid(width: 10, height: 10, fill: 9,
                      set: centerSet([.nan, .nan, .nan, .nan, .nan, 0.2, 0.4, 0.6, 0.8]))
    let m = median(values, width: 10, height: 10)
    #expect(abs((m ?? 0) - 0.5) < 1e-6)
}

@Test func allInvalidGivesNil() {
    #expect(median(grid(width: 10, height: 10, fill: .nan), width: 10, height: 10) == nil)
}

@Test func rowPaddingIsSkipped() {
    let values = grid(width: 10, height: 10, rowStride: 16, fill: 0.45, padding: 99)
    #expect(median(values, width: 10, height: 10, rowStride: 16) == 0.45)
}

@Test func tooSmallBufferGivesNil() {
    #expect(median([Float](repeating: 0.4, count: 50), width: 10, height: 10) == nil)
    #expect(median([], width: 0, height: 0) == nil)
}

@Test func statusThresholds() {
    #expect(DistanceEstimator.status(forMedian: nil) == .noData)
    #expect(DistanceEstimator.status(forMedian: 0.2) == .tooClose(meters: 0.2))
    #expect(DistanceEstimator.status(forMedian: 0.25) == .ok(meters: 0.25))
    #expect(DistanceEstimator.status(forMedian: 0.70) == .ok(meters: 0.70))
    #expect(DistanceEstimator.status(forMedian: 0.71) == .tooFar(meters: 0.71))
}

@Test func messages() {
    #expect(DistanceStatus.noData.message == "Brak danych głębi")
    #expect(DistanceStatus.tooClose(meters: 0.1).message == "Odsuń się")
    #expect(DistanceStatus.tooFar(meters: 1).message == "Przybliż się")
    #expect(DistanceStatus.ok(meters: 0.423).message == "OK — odległość 42 cm")
}
