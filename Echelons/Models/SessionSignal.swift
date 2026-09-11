import Foundation

/// Health of the location pipeline, kept separate from `PaceStatus`.
///
/// `PaceStatus` stays a pure description of pace (via `classify`), so the existing
/// pure-function tests and the exhaustive switches in ActivityView are unaffected.
enum SessionSignal: Sendable, Equatable {
    case acquiring
    case live
    case weak
    case stationary
    case noSignal
    case notInUse
    case accuracyLimited
    case denied(DenialReason)
}

/// How long to wait for a first usable sample before admitting there is no signal.
let acquiringWatchdogInterval: TimeInterval = 15

/// Moves a still-acquiring session to `.noSignal` once the watchdog interval passes
/// with nothing accepted.
///
/// This is the backstop that makes a permanently stuck ACQUIRING impossible: whatever
/// the underlying cause, the UI reports something actionable within the interval.
func watchdogSignal(
    current: SessionSignal,
    hasAcceptedSample: Bool,
    elapsedSinceStart: TimeInterval,
    threshold: TimeInterval = acquiringWatchdogInterval
) -> SessionSignal {
    guard current == .acquiring, !hasAcceptedSample, elapsedSinceStart >= threshold else {
        return current
    }
    return .noSignal
}
