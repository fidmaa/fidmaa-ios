import AVFoundation
import CoreGraphics
import FidmaaCore
import os
import QuartzCore
import Vision

enum MeasurementMode: Equatable {
    case none
    case mouth
    case neck
}

/// What the measurement pages show. Points are sensor-normalized (0...1, top-left, unmirrored),
/// i.e. AVFoundation "capture device" coordinates, so the preview layer can place them on screen.
struct MeasurementState: Equatable {
    enum Kind: Equatable {
        case teeth
        case lips
        case neck
    }

    var status: String?
    var kind: Kind?
    /// Meters.
    var current: Float?
    var maxTeeth: Float?
    var maxLips: Float?
    var maxNeck: Float?
    var from: CGPoint?
    var to: CGPoint?
    var outline: [CGPoint] = []
}

/// Runs Vision on synchronized video + depth frames and measures incisor distance / mouth opening
/// or the chin–neck depth difference, holding the maximum until reset.
final class LiveMeasurementEngine {
    static let interval: CFTimeInterval = 1.0 / 15
    /// Lips count as open above this distance (meters).
    static let lipsOpenThreshold: Float = 0.008

    var onUpdate: ((MeasurementState) -> Void)?

    private let queue = DispatchQueue(label: "fidmaa.measure", qos: .userInitiated)
    private let busy = OSAllocatedUnfairLock(initialState: false)
    /// Caller queue only (the capture synchronizer queue).
    private var lastRun: CFTimeInterval = 0
    // queue only
    private var teeth = PeakHold()
    private var lips = PeakHold()
    private var neck = PeakHold()
    private var lastMode = MeasurementMode.none

    private static let logger = Logger(subsystem: "com.fidmaa.pic", category: "measure")

    /// Called for every synchronized frame while a measurement page is shown; throttled and dropped
    /// while the previous frame is still being analyzed.
    func process(pixelBuffer: CVPixelBuffer, depth: DepthFrame, mode: MeasurementMode) {
        let now = CACurrentMediaTime()
        guard mode != .none, now - lastRun >= Self.interval else { return }
        guard busy.withLock({ wasBusy in
            if wasBusy { return false }
            wasBusy = true
            return true
        }) else { return }
        lastRun = now
        queue.async {
            defer { self.busy.withLock { $0 = false } }
            let state = self.analyze(pixelBuffer: pixelBuffer, depth: depth, mode: mode)
            self.onUpdate?(state)
        }
    }

    func reset(_ mode: MeasurementMode) {
        queue.async {
            switch mode {
            case .mouth:
                self.teeth.reset()
                self.lips.reset()
            case .neck:
                self.neck.reset()
            case .none:
                break
            }
            var state = MeasurementState()
            state.maxTeeth = self.teeth.maximum
            state.maxLips = self.lips.maximum
            state.maxNeck = self.neck.maximum
            self.onUpdate?(state)
        }
    }

    // MARK: - Analysis (queue)

    private func analyze(pixelBuffer: CVPixelBuffer, depth: DepthFrame, mode: MeasurementMode) -> MeasurementState {
        var state = MeasurementState()
        defer {
            state.maxTeeth = teeth.maximum
            state.maxLips = lips.maximum
            state.maxNeck = neck.maximum
        }
        guard let intrinsics = Self.intrinsics(depth) else {
            state.status = "Brak kalibracji kamery"
            return state
        }
        let request = VNDetectFaceLandmarksRequest()
        do {
            try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right).perform([request])
        } catch {
            Self.logger.error("Vision failed: \(error.localizedDescription, privacy: .public)")
            state.status = "Błąd wykrywania twarzy"
            return state
        }
        guard let face = request.results?.max(by: { Self.area($0) < Self.area($1) }),
              let landmarks = face.landmarks else {
            state.status = "Nie widzę twarzy"
            return state
        }
        let frame = Frame(pixelBuffer: pixelBuffer, depth: depth, intrinsics: intrinsics)
        switch mode {
        case .mouth: measureMouth(landmarks, frame: frame, state: &state)
        case .neck: measureNeck(landmarks, frame: frame, state: &state)
        case .none: break
        }
        return state
    }

    private func measureMouth(_ landmarks: VNFaceLandmarks2D, frame: Frame, state: inout MeasurementState) {
        guard let inner = landmarks.innerLips.map({ frame.upright($0) }), inner.count >= 4 else {
            state.status = "Nie widzę ust"
            return
        }
        state.outline = inner.map(frame.sensor)
        let cx = inner.map(\.x).reduce(0, +) / Double(inner.count)
        let cy = inner.map(\.y).reduce(0, +) / Double(inner.count)
        guard let upper = inner.filter({ $0.y < cy }).min(by: { abs($0.x - cx) < abs($1.x - cx) }),
              let lower = inner.filter({ $0.y >= cy }).min(by: { abs($0.x - cx) < abs($1.x - cx) }),
              let planeDepth = frame.medianDepth(around: inner.map(frame.sensor)) else {
            state.status = "Nie widzę ust"
            return
        }
        // Pixel profile from the upper to the lower inner lip, in the video buffer.
        let steps = max(20, Int((lower.y - upper.y) * Double(frame.uprightHeight)))
        let path = (0...steps).map { i -> CGPoint in
            let t = Double(i) / Double(steps)
            return CGPoint(x: upper.x + (lower.x - upper.x) * t, y: upper.y + (lower.y - upper.y) * t)
        }
        let profile = path.map { frame.sample(frame.sensor($0)) }
        let a: CGPoint
        let b: CGPoint
        if let edges = IncisorDetector.edges(profile) {
            a = frame.sensor(path[edges.upper])
            b = frame.sensor(path[edges.lower])
            state.kind = .teeth
        } else {
            a = frame.sensor(upper)
            b = frame.sensor(lower)
            state.kind = .lips
        }
        let distance = FaceGeometry.lateralDistance(frame.depthPixel(a), frame.depthPixel(b),
                                                    depth: planeDepth, intrinsics: frame.intrinsics)
        state.from = a
        state.to = b
        if state.kind == .lips && distance < Self.lipsOpenThreshold {
            state.status = "Usta zamknięte"
            state.current = distance
            return
        }
        state.current = state.kind == .teeth ? teeth.add(distance) : lips.add(distance)
    }

    private func measureNeck(_ landmarks: VNFaceLandmarks2D, frame: Frame, state: inout MeasurementState) {
        guard let contour = landmarks.faceContour.map({ frame.upright($0) }), !contour.isEmpty,
              let chin = contour.max(by: { $0.y < $1.y }) else {
            state.status = "Nie widzę brody"
            return
        }
        state.outline = contour.map(frame.sensor)
        // Chin depth from just above the contour (inside the face).
        let chinInside = CGPoint(x: chin.x, y: chin.y - 3 / Double(frame.depthUprightHeight))
        guard let chinDepth = frame.medianDepth(around: [frame.sensor(chinInside)]) else {
            state.status = "Brak głębi na brodzie"
            return
        }
        // Walk down (upright) one depth pixel at a time.
        let maxSteps = Int(Double(NeckProfile.maxOffset) / Double(chinDepth) * Double(frame.intrinsics.fx)) + 2
        var offsets: [Float] = []
        var depths: [Float] = []
        var points: [CGPoint] = []
        for k in 0...maxSteps {
            let p = CGPoint(x: chin.x, y: chin.y + Double(k) / Double(frame.depthUprightHeight))
            guard p.y < 1 else { break }
            let s = frame.sensor(p)
            points.append(s)
            offsets.append(Float(k) * chinDepth / frame.intrinsics.fx)  // upright vertical = sensor x
            depths.append(frame.depthValue(s))
        }
        state.from = frame.sensor(chin)
        guard let index = NeckProfile.deepest(offsetsMeters: offsets, depths: depths, chinDepth: chinDepth) else {
            state.status = "Nie widzę szyi — odchyl głowę lub opuść telefon"
            return
        }
        state.to = points[index]
        state.kind = .neck
        state.current = neck.add(depths[index] - chinDepth)
    }

    // MARK: - Helpers

    private static func area(_ face: VNFaceObservation) -> CGFloat {
        face.boundingBox.width * face.boundingBox.height
    }

    private static func intrinsics(_ depth: DepthFrame) -> Intrinsics? {
        guard let c = depth.calibration else { return nil }
        let k = c.intrinsicMatrix
        return Intrinsics.scaled(fx: k.columns.0.x, fy: k.columns.1.y, cx: k.columns.2.x, cy: k.columns.2.y,
                                 reference: Size2D(width: Double(c.intrinsicMatrixReferenceDimensions.width),
                                                   height: Double(c.intrinsicMatrixReferenceDimensions.height)),
                                 width: depth.width, height: depth.height)
    }
}

/// One synchronized video + depth frame with coordinate helpers.
private struct Frame {
    let pixelBuffer: CVPixelBuffer
    let depth: DepthFrame
    let intrinsics: Intrinsics

    var bufferWidth: Int { CVPixelBufferGetWidth(pixelBuffer) }
    var bufferHeight: Int { CVPixelBufferGetHeight(pixelBuffer) }
    /// Upright (Vision `.right`) image height in video pixels = buffer width.
    var uprightHeight: Int { bufferWidth }
    /// Upright height in depth pixels = depth width.
    var depthUprightHeight: Int { depth.width }

    /// Landmark region → upright-normalized points (top-left origin).
    func upright(_ region: VNFaceLandmarkRegion2D) -> [CGPoint] {
        let size = CGSize(width: bufferHeight, height: bufferWidth)
        return region.pointsInImage(imageSize: size).map {
            CGPoint(x: $0.x / size.width, y: 1 - $0.y / size.height)
        }
    }

    func sensor(_ upright: CGPoint) -> CGPoint {
        let s = UprightMapping.sensor(fromUpright: (x: Double(upright.x), y: Double(upright.y)))
        return CGPoint(x: s.x, y: s.y)
    }

    func depthPixel(_ sensor: CGPoint) -> (u: Float, v: Float) {
        (u: Float(sensor.x) * Float(depth.width), v: Float(sensor.y) * Float(depth.height))
    }

    func depthValue(_ sensor: CGPoint) -> Float {
        let x = Int(sensor.x * Double(depth.width)), y = Int(sensor.y * Double(depth.height))
        guard x >= 0, y >= 0, x < depth.width, y < depth.height else { return .nan }
        return depth.values[y * depth.width + x]
    }

    /// Median of valid depth in 3×3 windows around the given points.
    func medianDepth(around points: [CGPoint]) -> Float? {
        var values: [Float] = []
        for p in points {
            let x = Int(p.x * Double(depth.width)), y = Int(p.y * Double(depth.height))
            for dy in -1...1 {
                for dx in -1...1 {
                    let xx = x + dx, yy = y + dy
                    guard xx >= 0, yy >= 0, xx < depth.width, yy < depth.height else { continue }
                    let v = depth.values[yy * depth.width + xx]
                    if v.isFinite && v > 0 { values.append(v) }
                }
            }
        }
        guard !values.isEmpty else { return nil }
        values.sort()
        return values[values.count / 2]
    }

    /// Luma and saturation of the BGRA video pixel at a sensor-normalized point.
    func sample(_ sensor: CGPoint) -> PixelSample {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return PixelSample(luma: 0, saturation: 1) }
        let x = min(max(Int(sensor.x * Double(bufferWidth)), 0), bufferWidth - 1)
        let y = min(max(Int(sensor.y * Double(bufferHeight)), 0), bufferHeight - 1)
        let p = base.advanced(by: y * CVPixelBufferGetBytesPerRow(pixelBuffer) + x * 4).assumingMemoryBound(to: UInt8.self)
        let b = Float(p[0]) / 255, g = Float(p[1]) / 255, r = Float(p[2]) / 255
        let maxC = max(r, g, b), minC = min(r, g, b)
        return PixelSample(luma: 0.299 * r + 0.587 * g + 0.114 * b, saturation: maxC > 0 ? (maxC - minC) / maxC : 0)
    }
}
