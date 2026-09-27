import CoreMotion
import FidmaaCore
import os

/// Records device attitude at 100 Hz so depth frames taken during hand shake can be rejected.
final class MotionRecorder {
    struct Sample {
        /// Seconds since boot (same base as the capture session host clock).
        let timestamp: Double
        let attitude: Quaternion
    }

    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    private let samples = OSAllocatedUnfairLock<[Sample]>(initialState: [])
    /// Latest gravity in device coordinates (x right, y up, z out of the screen), in g.
    private let gravity = OSAllocatedUnfairLock<(x: Double, y: Double, z: Double)?>(initialState: nil)
    /// Samples older than this (relative to the newest) are dropped.
    private let retention: Double = 2.0
    private static let logger = Logger(subsystem: "com.fidmaa.pic", category: "motion")

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start() {
        guard manager.isDeviceMotionAvailable else {
            Self.logger.error("Device motion unavailable; frames will not be filtered by motion")
            return
        }
        guard !manager.isDeviceMotionActive else { return }
        queue.maxConcurrentOperationCount = 1
        manager.deviceMotionUpdateInterval = 1.0 / 100
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, error in
            guard let self else { return }
            if let error {
                Self.logger.error("Device motion error: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard let motion else { return }
            self.gravity.withLock { $0 = (motion.gravity.x, motion.gravity.y, motion.gravity.z) }
            let q = motion.attitude.quaternion
            let sample = Sample(timestamp: motion.timestamp, attitude: Quaternion(x: q.x, y: q.y, z: q.z, w: q.w))
            self.samples.withLock { samples in
                samples.append(sample)
                let cutoff = sample.timestamp - self.retention
                if let firstKept = samples.firstIndex(where: { $0.timestamp >= cutoff }), firstKept > 0 {
                    samples.removeFirst(firstKept)
                }
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }

    func latestGravity() -> (x: Double, y: Double, z: Double)? {
        gravity.withLock { $0 }
    }

    /// Sample closest to `timestamp`, or nil if none within `maxOffset` seconds.
    func sample(near timestamp: Double, maxOffset: Double = 0.05) -> Sample? {
        samples.withLock { samples in
            guard let index = MotionAlignment.nearestIndex(in: samples.map(\.timestamp), to: timestamp),
                  abs(samples[index].timestamp - timestamp) <= maxOffset else { return nil }
            return samples[index]
        }
    }
}
