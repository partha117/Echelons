import AVFoundation
import OSLog

@MainActor
final class PaceAnnouncer: NSObject {
    private let log = Logger(subsystem: "runners.Echelons", category: "audio")
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        // Leaving usesApplicationAudioSession at its default (true) is essential:
        // setting it false gives the synthesizer a private session and silently
        // ignores the category configured below, including background eligibility.
        synthesizer.delegate = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    /// Configures the audio session and warms up the synthesizer.
    ///
    /// Call while foreground at the start of a run. Configuring lazily on the first
    /// announcement would run in the background, and the first synthesis carries a
    /// noticeable latency that otherwise looks like "background audio is broken".
    func prepare() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .voicePrompt,
                options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
            )
            log.notice("audio session configured (usesApplicationAudioSession=\(self.synthesizer.usesApplicationAudioSession, privacy: .public))")
        } catch {
            log.error("audio session setCategory failed: \(error.localizedDescription, privacy: .public)")
        }

        let warmup = AVSpeechUtterance(string: " ")
        warmup.volume = 0
        warmup.voice = Self.preferredVoice()
        synthesizer.speak(warmup)
    }

    /// Speaks a pace correction. Returns whether speech was actually enqueued, so the
    /// caller only restarts its cadence clock when something was really said.
    @discardableResult
    func announce(speed: Double, unit: SpeedUnit, status: PaceStatus) -> Bool {
        let directionText: String
        switch status {
        case .tooFast: directionText = "Be slower."
        case .tooSlow: directionText = "Be faster."
        default: return false
        }
        guard !synthesizer.isSpeaking else {
            log.debug("announcement skipped — already speaking")
            return false
        }

        // Ducking happens only while the session is active, so it is activated per
        // utterance and deactivated in the delegate. Holding it active for the whole
        // run would duck the user's music from START to STOP.
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            log.error("audio session activation failed: \(error.localizedDescription, privacy: .public)")
            return false
        }

        let speedStr = String(format: "%.1f", speed)
        let utterance = AVSpeechUtterance(
            string: "Your current speed is \(speedStr) \(unit.label). \(directionText)"
        )
        utterance.voice = Self.preferredVoice()
        synthesizer.speak(utterance)
        return true
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        deactivate()
    }

    private func deactivate() {
        do {
            // .notifyOthersOnDeactivation is what tells a music app to un-duck.
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            log.error("audio session deactivation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func preferredVoice() -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice(language: Locale.preferredLanguages.first ?? "en-US")
    }

    @objc private nonisolated func handleInterruption(_ note: Notification) {
        Task { @MainActor [weak self] in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            // The per-utterance setActive(true) recovers automatically; logging keeps a
            // missed announcement explainable after the fact.
            self.log.notice("audio interruption: \(type == .began ? "began" : "ended", privacy: .public)")
        }
    }
}

extension PaceAnnouncer: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.deactivate() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.deactivate() }
    }
}
