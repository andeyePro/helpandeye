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

    /// `profile` says whether sounds and spoken words are on; touch stays on.
    /// The sound file the caller's profile chooses, or nil for none.
    static func file(_ sound: CallerFeedback.Sound, in profile: Profile) -> String? {
        switch sound {
        case .notSent:
            switch profile.notSent { case .eehOoh: "eeh-ooh"; case .buzzer: "buzzer"; case .none: nil }
        case .seen: profile.seen == .chime ? "seen" : nil
        }
    }

    /// Plays one of the caller's sounds, also so a choice can be heard before it is made.
    func play(_ file: String?) {
        // Heard with the ringer off: someone who pressed for help is waiting to know.
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
        guard let file, let url = Bundle.main.url(forResource: file, withExtension: "wav") else { player = nil; return }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
    }

    func tell(_ feedback: CallerFeedback, profile: Profile) {
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
        guard profile.soundsAndSpeech else { return }
        let file = feedback.sound.flatMap { Self.file($0, in: profile) }
        play(file)
        guard !voiceOver else { return }
        let words = AVSpeechUtterance(string: feedback.spoken)
        // After the sound, not over it.
        words.preUtteranceDelay = file == nil ? 0 : (player?.duration ?? 0) + 0.2
        speech.stopSpeaking(at: .immediate)
        speech.speak(words)
    }
}
