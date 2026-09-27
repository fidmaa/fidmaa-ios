import AudioToolbox
import UIKit

/// Sounds and haptics around a capture (call on the main thread).
/// The shutter sound itself is played by iOS and cannot be turned off.
/// System sound IDs are not public API constants but are stable and widely used;
/// they follow the ring/silent switch, haptics do not.
enum CaptureFeedback {
    private static let exposureEndedSound: SystemSoundID = 1118  // end_video_record
    private static let savedSound: SystemSoundID = 1111          // jbl_confirm — short confirmation
    private static let warningSound: SystemSoundID = 1053        // SIMToolkitNegativeACK — single soft tone
    private static let errorSound: SystemSoundID = 1073          // ct-error (call failed) — only for real failures

    /// Shutter pressed.
    static func shutter() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Photo exposure finished — the user may move.
    static func exposureEnded() {
        AudioServicesPlaySystemSound(exposureEndedSound)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Capture saved: confirmation, or a softer tone when there were warnings (e.g. no mattes).
    static func saved(hasWarnings: Bool) {
        if hasWarnings {
            AudioServicesPlaySystemSound(warningSound)
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        } else {
            AudioServicesPlaySystemSound(savedSound)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    static func failed() {
        AudioServicesPlaySystemSound(errorSound)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
