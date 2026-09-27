import Testing
@testable import FidmaaCore

@Test func identicalMapsMatch() {
    let s = DepthComparison.compare(expected: [0.3, 0.5, .nan], actual: [0.3, 0.5, .nan])
    #expect(s.validPairs == 2)
    #expect(s.medianAbsDifference == 0)
    #expect(s.fractionOverTolerance == 0)
    #expect(s.isAcceptable)
}

@Test func invertedMapIsRejected() {
    let expected: [Float] = [0.35, 0.36, 0.4, 2.0]
    let s = DepthComparison.compare(expected: expected, actual: expected.map { 1 / $0 })
    #expect(!s.isAcceptable)
}

@Test func tinyQuantizationIsAccepted() {
    let expected: [Float] = (0..<100).map { 0.3 + Float($0) * 0.01 }
    let s = DepthComparison.compare(expected: expected, actual: expected.map { $0 + 0.0002 })
    #expect(s.isAcceptable)
}

@Test func noValidPairsIsRejected() {
    #expect(!DepthComparison.compare(expected: [.nan], actual: [0.3]).isAcceptable)
    #expect(!DepthComparison.compare(expected: [0.3], actual: [0.3, 0.4]).isAcceptable)
}
