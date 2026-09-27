import FidmaaCore
import Foundation

/// Writes the multi-frame depth stack: raw frames, per-pixel median/std/count and frames.json.
enum StackExporter {
    /// Returns nil (with a warning) when no streamed frames were available.
    static func export(_ stack: StackCapture, to folder: URL, warnings: inout [String]) throws -> StackInfo? {
        guard let reference = stack.frames.last else {
            warnings.append("Brak klatek ze strumienia głębi — pominięto uśrednianie")
            return nil
        }
        let referenceIndex = stack.frames.count - 1
        let referenceAttitude = stack.motion[referenceIndex]?.attitude
        let angles: [Double?] = stack.motion.map { sample in
            guard let sample, let referenceAttitude else { return nil }
            return MotionAlignment.angleDegrees(sample.attitude, referenceAttitude)
        }
        let used = MotionAlignment.selectFrames(angles: angles, threshold: CaptureConfig.stackRotationThresholdDegrees)
        let usedFrames = zip(stack.frames, used).filter(\.1).map(\.0.values)
        let result = DepthStackStatistics.compute(frames: usedFrames, pixelCount: reference.width * reference.height)

        try DepthRaw.littleEndianData(frames: stack.frames.map(\.values))
            .write(to: folder.appendingPathComponent("depth_stack.f32"))
        try DepthRaw.littleEndianData(frames: [result.median]).write(to: folder.appendingPathComponent("depth_median.f32"))
        try DepthRaw.littleEndianData(frames: [result.std]).write(to: folder.appendingPathComponent("depth_std.f32"))
        try Data(result.count).write(to: folder.appendingPathComponent("depth_count.u8"))

        let records = stack.frames.indices.map { i in
            FrameRecord(index: i, timestamp: stack.frames[i].timestamp, rotationFromReferenceDegrees: angles[i],
                        motionTimeOffsetSeconds: stack.motion[i].map { abs($0.timestamp - stack.frames[i].timestamp) },
                        used: used[i])
        }
        let framesFile = FramesFile(referenceFrameIndex: referenceIndex, frames: records,
                                    streamCalibration: reference.calibration.map(CaptureExporter.makeCalibration))
        try FidmaaJSON.encode(framesFile).write(to: folder.appendingPathComponent("frames.json"))

        let usedCount = usedFrames.count
        if usedCount < stack.requestedFrames {
            warnings.append("Trzymaj stabilniej — uśredniono \(usedCount) z \(stack.requestedFrames) klatek")
        }
        if !stack.motionAvailable || referenceAttitude == nil {
            warnings.append("Brak danych z żyroskopu — uśredniono wszystkie klatki")
        }
        let window = (stack.frames.last?.timestamp ?? 0) - (stack.frames.first?.timestamp ?? 0)
        return StackInfo(requestedFrames: stack.requestedFrames, windowSeconds: window, framesCaptured: stack.frames.count,
                         framesUsed: usedCount, rotationThresholdDegrees: CaptureConfig.stackRotationThresholdDegrees,
                         width: reference.width, height: reference.height,
                         motionAvailable: stack.motionAvailable && referenceAttitude != nil)
    }
}
