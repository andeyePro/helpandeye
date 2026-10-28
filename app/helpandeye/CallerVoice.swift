import AVFoundation
import helpandeyeCore
import SwiftUI
#if os(watchOS)
import WatchKit
#else
import UIKit
#endif

/// Lets a caller know by sound and touch what happened to their call, on the phone and on the
/// watch. With VoiceOver on, the words go to VoiceOver instead of being spoken a second time.
@MainActor
final class CallerVoice {
    static let shared = CallerVoice()
    /// The caller's choice to hear sounds and words; touch stays on. Kept on this device.
    static let key = "callerSounds"

    private let speech = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?

    /// A short tap, so a press is felt to have registered.
    func pressed() {
        #if os(watchOS)
        WKInterfaceDevice.current().play(.click)
        #else
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }

    func tell(_ feedback: CallerFeedback) {
        #if os(watchOS)
        if let sound = feedback.sound { WKInterfaceDevice.current().play(sound == .seen ? .success : .failure) }
        let voiceOver = WKAccessibilityIsVoiceOverRunning()
        #else
        if let sound = feedback.sound { UINotificationFeedbackGenerator().notificationOccurred(sound == .seen ? .success : .error) }
        let voiceOver = UIAccessibility.isVoiceOverRunning
        #endif
        if voiceOver {
            AccessibilityNotification.Announcement(feedback.spoken).post()
        }
        guard UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true else { return }
        // Heard with the ringer off: someone who pressed for help is waiting to know.
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
        if let sound = feedback.sound,
           let url = Bundle.main.url(forResource: sound == .seen ? "seen" : "not-sent", withExtension: "wav") {
            player = try? AVAudioPlayer(contentsOf: url)
            player?.play()
        }
        guard !voiceOver else { return }
        let words = AVSpeechUtterance(string: feedback.spoken)
        // After the sound, not over it.
        words.preUtteranceDelay = feedback.sound == nil ? 0 : (player?.duration ?? 0) + 0.2
        speech.stopSpeaking(at: .immediate)
        speech.speak(words)
    }
}

/// The switch for sounds and spoken words, on the phone and on the watch.
struct CallerVoiceToggle: View {
    @AppStorage(CallerVoice.key) private var on = true

    var body: some View {
        Toggle("Sounds and spoken words", isOn: $on)
            .accessibilityHint("Says out loud whether your call went, and when someone has seen it")
    }
}
