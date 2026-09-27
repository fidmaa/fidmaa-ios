import AVFoundation
import os

/// One streamed depth frame, converted to Float32 meters and packed without row padding.
struct DepthFrame {
    /// Capture session host-clock time, seconds.
    let timestamp: Double
    let width: Int
    let height: Int
    let values: [Float]
    let calibration: AVCameraCalibrationData?
}

/// Keeps the most recent streamed depth frames for multi-frame averaging.
final class DepthFrameBuffer {
    private let frames = OSAllocatedUnfairLock<[DepthFrame]>(initialState: [])
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    func append(_ frame: DepthFrame) {
        frames.withLock { frames in
            frames.append(frame)
            if frames.count > capacity { frames.removeFirst(frames.count - capacity) }
        }
    }

    /// Frames from the last `window` seconds (relative to the newest), oldest first,
    /// restricted to the newest frame's dimensions.
    func snapshot(window: Double) -> [DepthFrame] {
        frames.withLock { frames in
            guard let newest = frames.last else { return [] }
            return frames.filter {
                $0.timestamp >= newest.timestamp - window && $0.width == newest.width && $0.height == newest.height
            }
        }
    }
}
