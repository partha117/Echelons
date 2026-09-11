import Foundation

enum PaceStatus: Equatable {
    case acquiring, inRange, tooSlow, tooFast
}

// Pure functions extracted for testability — no GPS, no AVAudio needed.

func classify(speed: Double, min: Double, max: Double) -> PaceStatus {
    if speed < min { return .tooSlow }
    if speed > max { return .tooFast }
    return .inRange
}

func shouldAnnounce(
    status: PaceStatus,
    lastAnnouncement: Date?,
    now: Date,
    interval: TimeInterval
) -> Bool {
    guard status == .tooSlow || status == .tooFast else { return false }
    guard let last = lastAnnouncement else { return true }
    return now.timeIntervalSince(last) >= interval
}
