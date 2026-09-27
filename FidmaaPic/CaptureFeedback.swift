import AudioToolbox
import UIKit

/// Sounds and haptics around a capture (call on the main thread).
/// The shutter sound itself is played by iOS and cannot be turned off.
/// System sound IDs are not public API constants but are stable and widely used;
/// they follow the ring/silent switch, haptics do not.
enum CaptureFeedback {
    private static let exposureEndedSound: SystemSoundID = 1118  // "end video recording"
    private static let warningSound: SystemSoundID = 1073        // short negative beep

    /// Shutter pressed.
    static func shutter() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Photo exposure finished — the user may move.
    static func exposureEnded() {
        AudioServicesPlaySystemSound(exposureEndedSound)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Capture saved; warnings (e.g. rejected frames) get a sound, a clean save only a haptic.
    static func saved(hasWarnings: Bool) {
        if hasWarnings {
            AudioServicesPlaySystemSound(warningSound)
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    static func failed() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
