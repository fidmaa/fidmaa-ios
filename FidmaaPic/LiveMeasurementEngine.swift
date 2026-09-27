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
        /// Thyromental height to the thyroid cartilage prominence.
        case thyroid
        /// Fallback: chin to the submental recess (no thyroid prominence found).
        case recess
    }

    var status: String?
    var kind: Kind?
    /// Meters.
    var current: Float?
    var maxTeeth: Float?
    var maxLips: Float?
    /// Steady (2 s median) thyromental height and its recess fallback, meters.
    var steadyThyroid: Float?
    var steadyRecess: Float?
    /// Camera pitch above the horizon (TMHT page), degrees.
    var pitchDegrees: Double?
    var from: CGPoint?
    var to: CGPoint?
    var outline: [CGPoint] = []
    /// Mouth profile samples and whether each was classified as tooth (drawn for troubleshooting).
    var profile: [CGPoint] = []
    var profileTooth: [Bool] = []
    /// Luma range along the mouth profile (troubleshooting).
    var profileLuma: ClosedRange<Float>?
    /// Small diagnostic line (rotation, frame sizes) for remote troubleshooting.
    var debug: String?
}

/// Runs Vision on synchronized video + depth frames and measures incisor distance / mouth opening
/// or the chin–neck depth difference, holding the maximum until reset.
final class LiveMeasurementEngine {
    static let interval: CFTimeInterval = 1.0 / 15
    /// Depth is the per-pixel median of this many recent streamed frames (≈2× less noise than one frame).
    static let depthFrames = 5
    /// Frames written by one diagnostic long press (≈2 s).
    static let burstFrames = 30
    /// Lips count as open above this distance (meters).
    static let lipsOpenThreshold: Float = 0.008

    var onUpdate: ((MeasurementState) -> Void)?

    private let queue = DispatchQueue(label: "fidmaa.measure", qos: .userInitiated)
    private let busy = OSAllocatedUnfairLock(initialState: false)
    /// Frames still to be written by a diagnostic burst (long press on the TMHT page).
    private let burstRemaining = OSAllocatedUnfairLock(initialState: 0)
    // queue only
    private var burstFolder: URL?
    private var burstIndex = 0
    private var smoothed: (axis: FaceAxis, menton: Double, lipBottom: Double)?
    private var lastFaceTime: CFTimeInterval = 0
    private var pogonionGate = StabilityGate(window: 1.0, maxSpread: 0.003, minSamples: 8)
    private var neckGate = StabilityGate(window: 1.0, maxSpread: 0.003, minSamples: 8)
    /// Axis/landmark smoothing factor per analyzed frame (15 Hz).
    private static let smoothing = 0.3

    func requestDiagnosticSnapshot() {
        burstRemaining.withLock { $0 = Self.burstFrames }
    }
    /// Caller queue only (the capture synchronizer queue).
    private var lastRun: CFTimeInterval = 0
    // queue only
    private var teeth = PeakHold()
    private var lips = PeakHold()
    private var thyroidMedian = RollingMedian(window: 2)
    private var recessMedian = RollingMedian(window: 2)
    private var steadyThyroid: Float?
    private var steadyRecess: Float?

    private static let logger = Logger(subsystem: "com.fidmaa.pic", category: "measure")

    /// Called for every synchronized frame while a measurement page is shown; throttled and dropped
    /// while the previous frame is still being analyzed.
    func process(pixelBuffer: CVPixelBuffer, depth: DepthFrame, recentDepth: [DepthFrame], mode: MeasurementMode,
                 rotationDegrees: Int, gravity: (x: Double, y: Double, z: Double)?) {
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
            var state = self.analyze(pixelBuffer: pixelBuffer, depth: depth, recentDepth: recentDepth, mode: mode,
                                     rotationDegrees: rotationDegrees, gravity: gravity, time: now)
            // Held values are read after the measurement updated them.
            self.fillHeld(&state)
            state.debug = "\(rotationDegrees)° · \(CVPixelBufferGetWidth(pixelBuffer))×\(CVPixelBufferGetHeight(pixelBuffer))"
                + " · \(depth.width)×\(depth.height)"
                + (state.profileLuma.map { String(format: " · luma %.2f–%.2f", $0.lowerBound, $0.upperBound) } ?? "")
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
                self.thyroidMedian.reset()
                self.recessMedian.reset()
                self.steadyThyroid = nil
                self.steadyRecess = nil
            case .none:
                break
            }
            var state = MeasurementState()
            self.fillHeld(&state)
            self.onUpdate?(state)
        }
    }

    private func fillHeld(_ state: inout MeasurementState) {
        state.maxTeeth = teeth.maximum
        state.maxLips = lips.maximum
        state.steadyThyroid = steadyThyroid
        state.steadyRecess = steadyRecess
    }

    // MARK: - Analysis (queue)

    private func analyze(pixelBuffer: CVPixelBuffer, depth: DepthFrame, recentDepth: [DepthFrame], mode: MeasurementMode,
                         rotationDegrees: Int, gravity: (x: Double, y: Double, z: Double)?,
                         time: CFTimeInterval) -> MeasurementState {
        var state = MeasurementState()
        guard let intrinsics = Self.intrinsics(depth) else {
            state.status = String(localized: "Brak kalibracji kamery")
            return state
        }
        let request = VNDetectFaceLandmarksRequest()
        do {
            try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: Self.orientation(rotationDegrees))
                .perform([request])
        } catch {
            Self.logger.error("Vision failed: \(error.localizedDescription, privacy: .public)")
            state.status = String(localized: "Błąd wykrywania twarzy")
            return state
        }
        guard let face = request.results?.max(by: { Self.area($0) < Self.area($1) }),
              let landmarks = face.landmarks else {
            state.status = String(localized: "Nie widzę twarzy")
            return state
        }
        let frame = Frame(pixelBuffer: pixelBuffer, depth: depth, intrinsics: intrinsics, rotation: rotationDegrees,
                          recentDepth: recentDepth.filter { $0.width == depth.width && $0.height == depth.height })
        switch mode {
        case .mouth: measureMouth(landmarks, frame: frame, state: &state)
        case .neck: measureThyromental(landmarks, frame: frame, gravity: gravity, time: time, state: &state)
        case .none: break
        }
        return state
    }

    private func measureMouth(_ landmarks: VNFaceLandmarks2D, frame: Frame, state: inout MeasurementState) {
        guard let inner = landmarks.innerLips.map({ frame.upright($0) }), inner.count >= 4 else {
            state.status = String(localized: "Nie widzę ust")
            return
        }
        state.outline = inner.map(frame.sensor)
        let cx = inner.map(\.x).reduce(0, +) / Double(inner.count)
        let cy = inner.map(\.y).reduce(0, +) / Double(inner.count)
        guard let upper = inner.filter({ $0.y < cy }).min(by: { abs($0.x - cx) < abs($1.x - cx) }),
              let lower = inner.filter({ $0.y >= cy }).min(by: { abs($0.x - cx) < abs($1.x - cx) }),
              let planeDepth = frame.medianDepth(around: inner.map(frame.sensor)) else {
            state.status = String(localized: "Nie widzę ust")
            return
        }
        // Pixel profile from the upper to the lower inner lip, in the video buffer.
        let steps = max(20, Int((lower.y - upper.y) * Double(frame.uprightSize.height)))
        let path = (0...steps).map { i -> CGPoint in
            let t = Double(i) / Double(steps)
            return CGPoint(x: upper.x + (lower.x - upper.x) * t, y: upper.y + (lower.y - upper.y) * t)
        }
        let profile = path.map { frame.sample(frame.sensor($0)) }
        state.profile = path.map(frame.sensor)
        state.profileTooth = IncisorDetector.classify(profile)
        if let lo = profile.map(\.luma).min(), let hi = profile.map(\.luma).max() { state.profileLuma = lo...hi }
        let a: CGPoint
        let b: CGPoint
        let distance: Float
        if let runs = IncisorDetector.toothRuns(profile) {
            // Incisal edges, each at the depth of its own tooth surface (median along the tooth run —
            // the edge pixel itself borders the cavity and its depth is unreliable). 3D, like a tape.
            a = frame.sensor(path[runs.upper.upperBound - 1])
            b = frame.sensor(path[runs.lower.lowerBound])
            let upperDepth = frame.medianDepth(around: runs.upper.map { frame.sensor(path[$0]) }) ?? planeDepth
            let lowerDepth = frame.medianDepth(around: runs.lower.map { frame.sensor(path[$0]) }) ?? planeDepth
            distance = FaceGeometry.distance3D(frame.depthPixel(a), depthA: upperDepth,
                                               frame.depthPixel(b), depthB: lowerDepth, intrinsics: frame.intrinsics)
            state.kind = .teeth
        } else {
            a = frame.sensor(upper)
            b = frame.sensor(lower)
            distance = FaceGeometry.lateralDistance(frame.depthPixel(a), frame.depthPixel(b),
                                                    depth: planeDepth, intrinsics: frame.intrinsics)
            state.kind = .lips
        }
        state.from = a
        state.to = b
        if state.kind == .lips && distance < Self.lipsOpenThreshold {
            state.status = String(localized: "Usta zamknięte")
            state.current = distance
            return
        }
        state.current = state.kind == .teeth ? teeth.add(distance) : lips.add(distance)
    }

    /// Thyromental height for a patient sitting upright with the head supported. Everything is located in
    /// the face's own frame (so head pitch doesn't matter): the axis is Vision's facial median line, the
    /// menton is its last point, the chin's anterior point (pogonion) is the profile point most in front of
    /// the nasion–menton line, the thyroid cartilage is the first plausible forward bump past the submental
    /// recess (fallback: the recess). The height is measured along the horizontal direction.
    private func measureThyromental(_ landmarks: VNFaceLandmarks2D, frame: Frame,
                                    gravity: (x: Double, y: Double, z: Double)?, time: CFTimeInterval,
                                    state: inout MeasurementState) {
        guard let median = landmarks.medianLine.map({ frame.upright($0) }), median.count >= 3,
              let outerLips = landmarks.outerLips.map({ frame.upright($0) }), !outerLips.isEmpty,
              let contour = landmarks.faceContour.map({ frame.upright($0) }), contour.count >= 3 else {
            state.status = String(localized: "Nie widzę twarzy")
            return
        }
        // Work in upright depth-grid pixels.
        let size = frame.depthUprightSize
        func px(_ p: CGPoint) -> (x: Double, y: Double) { (Double(p.x) * size.width, Double(p.y) * size.height) }
        let fitted = FaceAxis.fit(median.map(px))
        let rawMenton = fitted.along(px(median[median.count - 1]))
        let rawLipBottom = outerLips.map { fitted.along(px($0)) }.max() ?? 0
        // Vision's landmarks jitter by a few pixels per frame: smooth the axis and the chin in time,
        // but start over after a jump (face moved) or a gap.
        var axis = fitted
        var menton = rawMenton
        var lipBottom = rawLipBottom
        if let previous = smoothed, time - lastFaceTime < 0.5,
           hypot(previous.axis.origin.x - fitted.origin.x, previous.axis.origin.y - fitted.origin.y) < 20,
           abs(previous.menton - rawMenton) < 20 {
            let a = Self.smoothing
            let ox = previous.axis.origin.x + a * (fitted.origin.x - previous.axis.origin.x)
            let oy = previous.axis.origin.y + a * (fitted.origin.y - previous.axis.origin.y)
            var dx = previous.axis.dir.x + a * (fitted.dir.x - previous.axis.dir.x)
            var dy = previous.axis.dir.y + a * (fitted.dir.y - previous.axis.dir.y)
            let n = hypot(dx, dy)
            dx /= n
            dy /= n
            axis = FaceAxis(origin: (ox, oy), dir: (dx, dy))
            menton = previous.menton + a * (rawMenton - previous.menton)
            lipBottom = previous.lipBottom + a * (rawLipBottom - previous.lipBottom)
        } else {
            pogonionGate.reset()
            neckGate.reset()
        }
        smoothed = (axis, menton, lipBottom)
        lastFaceTime = time
        let across = contour.map { axis.across(px($0)) }
        let faceWidth = (across.max() ?? 0) - (across.min() ?? 0)
        let halfBand = max(2, 0.075 * faceWidth)
        state.outline = median.map(frame.sensor)
        guard menton > lipBottom else {
            state.status = String(localized: "Nie widzę brody")
            return
        }

        let h = gravity.map(MeasurementDirection.horizontal) ?? Point3(x: 0, y: 0, z: 1)
        state.pitchDegrees = gravity.map(MeasurementDirection.pitchDegrees)
        func upright(_ s: Double, _ l: Double) -> CGPoint {
            let q = axis.point(along: s, across: l)
            return CGPoint(x: q.x / size.width, y: q.y / size.height)
        }
        func point(_ s: Double, _ l: Double) -> Point3? {
            let u = upright(s, l)
            guard u.x >= 0, u.x < 1, u.y >= 0, u.y < 1 else { return nil }
            let sensor = frame.sensor(u)
            let z = frame.depthValue(sensor)
            guard z.isFinite, z > 0 else { return nil }
            let d = frame.depthPixel(sensor)
            return MeasurementDirection.uprightCamera(fromSensor: frame.intrinsics.unproject(u: d.u, v: d.v, depth: z),
                                                      rotationDegrees: frame.rotation)
        }
        /// Median over the band across the axis of a per-point quantity.
        func band(_ s: Double, _ f: (Point3) -> Float) -> Float? {
            var values = stride(from: -halfBand, through: halfBand, by: 1).compactMap { point(s, $0).map(f) }
            guard !values.isEmpty else { return nil }
            values.sort()
            return values[values.count / 2]
        }

        guard let nasionDepth = band(0, \.z), let mentonDepth = band(menton, \.z) else {
            state.status = String(localized: "Brak głębi na brodzie")
            return
        }
        let focal = Double(frame.isSideways ? frame.intrinsics.fx : frame.intrinsics.fy)
        let pixelsPerMeter = focal / Double(mentonDepth)
        // Pogonion: between a quarter of the way from the lower lip to the menton, and the menton.
        let chinSamples = Array(stride(from: lipBottom + 0.25 * (menton - lipBottom), through: menton, by: 1))
        // Forward distance of each profile sample from the nasion–menton line; the chin is flat near its
        // front, so take the middle of all samples within 1 mm of the best rather than the noisy winner.
        let forward: [Float] = chinSamples.map { s in
            guard let z = band(s, \.z) else { return .nan }
            return nasionDepth + (mentonDepth - nasionDepth) * Float(s / menton) - z
        }
        guard let best = forward.filter(\.isFinite).max(), best > 0,
              let pogIndex = Plateau.center(scores: forward, tolerance: 0.001),
              let pogonion = band(chinSamples[pogIndex], { $0.dot(h) }) else {
            state.status = String(localized: "Brak głębi na brodzie")
            return
        }
        let pogonionS = chinSamples[pogIndex]
        state.from = frame.sensor(upright(pogonionS, 0))

        var diagnostic: [String: Any] = [:]
        let snapshot = burstRemaining.withLock { remaining in
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
        defer {
            if snapshot {
                if burstFolder == nil || burstIndex >= Self.burstFrames {
                    burstFolder = Self.newDiagnosticsFolder()
                    burstIndex = 0
                }
                if let folder = burstFolder {
                    diagnostic["time"] = time
                    Self.writeSnapshot(diagnostic, frame: frame,
                                       to: folder.appendingPathComponent(String(format: "%02d", burstIndex)))
                }
                burstIndex += 1
                if burstRemaining.withLock({ $0 }) == 0 { burstFolder = nil }
            }
        }

        // Neck profile along the axis below the menton, relative to the pogonion.
        let steps = Int(Double(ThyromentalProfile.thyroidMaxOffset) * pixelsPerMeter) + 1
        var offsets: [Float] = []
        var values: [Float] = []
        for k in 0...steps {
            offsets.append(Float(Double(k) / pixelsPerMeter))
            values.append(band(menton + Double(k), { $0.dot(h) }).map { $0 - pogonion } ?? .nan)
        }
        let result = ThyromentalProfile.analyze(offsetsMeters: offsets, values: values)
        if snapshot {
            func pts(_ r: VNFaceLandmarkRegion2D?) -> [[Double]] {
                r.map { frame.upright($0).map { [Double($0.x), Double($0.y)] } } ?? []
            }
            diagnostic = [
                "rotation": frame.rotation, "depthUprightSize": [size.width, size.height],
                "intrinsics": [frame.intrinsics.fx, frame.intrinsics.fy, frame.intrinsics.cx, frame.intrinsics.cy],
                "gravity": gravity.map { [$0.x, $0.y, $0.z] } ?? [], "h": [h.x, h.y, h.z],
                "axisOrigin": [axis.origin.x, axis.origin.y], "axisDir": [axis.dir.x, axis.dir.y],
                "faceWidth": faceWidth, "halfBand": halfBand, "lipBottom": lipBottom, "menton": menton,
                "nasionDepth": nasionDepth, "mentonDepth": mentonDepth, "pogonionS": pogonionS,
                "profile": ["offsets": offsets.map(Double.init), "values": values.map { $0.isFinite ? Double($0) : -1 },
                            "recess": result.recess ?? -1, "thyroid": result.thyroid ?? -1],
                "landmarks": ["medianLine": pts(landmarks.medianLine), "outerLips": pts(landmarks.outerLips),
                              "innerLips": pts(landmarks.innerLips), "faceContour": pts(landmarks.faceContour),
                              "noseCrest": pts(landmarks.noseCrest)],
            ]
        }
        guard let index = result.thyroid ?? result.recess else {
            state.status = String(localized: "Nie widzę szyi — odchyl głowę lub opuść telefon")
            return
        }
        state.to = frame.sensor(upright(menton + Double(index), 0))
        state.kind = result.thyroid != nil ? .thyroid : .recess

        // The definition requires a closed mouth.
        if let inner = landmarks.innerLips.map({ frame.upright($0) }), inner.count >= 4 {
            let ys = inner.map { axis.along(px($0)) }
            let opening = Float((ys.max() ?? 0) - (ys.min() ?? 0)) / Float(pixelsPerMeter)
            if opening > Self.lipsOpenThreshold {
                state.status = String(localized: "Zamknij usta")
                return
            }
        }
        // Show a result only once both points have settled (≤ 3 mm movement over ~1 s).
        let chinStable = pogonionGate.add(Float(pogonionS / pixelsPerMeter), at: time)
        let neckStable = neckGate.add(Float((menton + Double(index)) / pixelsPerMeter), at: time)
        guard chinStable && neckStable else {
            state.status = String(localized: "Trzymaj nieruchomo — stabilizuję")
            return
        }
        state.current = values[index]
        if result.thyroid != nil {
            steadyThyroid = thyroidMedian.add(values[index], at: time)
        } else {
            steadyRecess = recessMedian.add(values[index], at: time)
        }
    }

    /// Documents/diagnostics/<time>/ for one burst.
    private static func newDiagnosticsFolder() -> URL? {
        do {
            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                        appropriateFor: nil, create: true)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
            return documents.appendingPathComponent("diagnostics", isDirectory: true)
                .appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        } catch {
            logger.error("No Documents folder for diagnostics: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Writes diag.json, depth.f32 (newest frame) and frame.jpg (sensor orientation) to `folder`.
    private static func writeSnapshot(_ diagnostic: [String: Any], frame: Frame, to folder: URL) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: diagnostic, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("diag.json"))
            try DepthRaw.littleEndianData(frames: [frame.depth.values]).write(to: folder.appendingPathComponent("depth.f32"))
            try frame.jpeg().write(to: folder.appendingPathComponent("frame.jpg"))
            logger.info("Diagnostic snapshot written to \(folder.path, privacy: .public)")
        } catch {
            logger.error("Writing diagnostic snapshot failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Helpers

    /// Clockwise rotation that makes the sensor frame upright → Vision orientation.
    private static func orientation(_ rotationDegrees: Int) -> CGImagePropertyOrientation {
        switch ((rotationDegrees % 360) + 360) % 360 {
        case 90: .right
        case 180: .down
        case 270: .left
        default: .up
        }
    }

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
    /// Clockwise degrees that make the sensor frame upright.
    let rotation: Int
    /// Recent depth frames (same size, newest last) whose per-pixel median replaces the single frame.
    let recentDepth: [DepthFrame]

    var bufferWidth: Int { CVPixelBufferGetWidth(pixelBuffer) }
    var bufferHeight: Int { CVPixelBufferGetHeight(pixelBuffer) }
    var isSideways: Bool { ((rotation % 180) + 180) % 180 != 0 }
    /// Upright image size in video pixels.
    var uprightSize: CGSize {
        isSideways ? CGSize(width: bufferHeight, height: bufferWidth) : CGSize(width: bufferWidth, height: bufferHeight)
    }
    /// Upright size in depth pixels.
    var depthUprightSize: CGSize {
        isSideways ? CGSize(width: depth.height, height: depth.width) : CGSize(width: depth.width, height: depth.height)
    }

    /// Landmark region → upright-normalized points (top-left origin).
    func upright(_ region: VNFaceLandmarkRegion2D) -> [CGPoint] {
        let size = uprightSize
        return region.pointsInImage(imageSize: size).map {
            CGPoint(x: $0.x / size.width, y: 1 - $0.y / size.height)
        }
    }

    func sensor(_ upright: CGPoint) -> CGPoint {
        let s = UprightMapping.sensor(fromUpright: (x: Double(upright.x), y: Double(upright.y)), rotationDegrees: rotation)
        return CGPoint(x: s.x, y: s.y)
    }

    func depthPixel(_ sensor: CGPoint) -> (u: Float, v: Float) {
        (u: Float(sensor.x) * Float(depth.width), v: Float(sensor.y) * Float(depth.height))
    }

    func depthValue(_ sensor: CGPoint) -> Float {
        let x = Int(sensor.x * Double(depth.width)), y = Int(sensor.y * Double(depth.height))
        guard x >= 0, y >= 0, x < depth.width, y < depth.height else { return .nan }
        return depthAt(x: x, y: y)
    }

    /// Median over the recent frames of the valid depth at a depth-grid pixel (NaN if none is valid).
    func depthAt(x: Int, y: Int) -> Float {
        let i = y * depth.width + x
        guard recentDepth.count > 1 else { return depth.values[i] }
        var values = recentDepth.map { $0.values[i] }.filter { $0.isFinite && $0 > 0 }
        guard !values.isEmpty else { return .nan }
        values.sort()
        return values[values.count / 2]
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
                    let v = depthAt(x: xx, y: yy)
                    if v.isFinite && v > 0 { values.append(v) }
                }
            }
        }
        guard !values.isEmpty else { return nil }
        values.sort()
        return values[values.count / 2]
    }

    /// The BGRA video frame as JPEG (sensor orientation).
    func jpeg() throws -> Data {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let data = NSMutableData()
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(data: base, width: bufferWidth, height: bufferHeight, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                                          | CGImageAlphaInfo.noneSkipFirst.rawValue),
              let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw CaptureExportError.noPhotoData
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CaptureExportError.noPhotoData }
        return data as Data
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
