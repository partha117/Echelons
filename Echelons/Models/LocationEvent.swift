import Foundation

enum SignalQuality: Sendable, Equatable {
    case good, degraded
}

enum DenialReason: Sendable, Equatable {
    case appDenied, deniedGlobally, restricted

    var message: String {
        switch self {
        case .appDenied:      "Open Settings to allow location while using the app."
        case .deniedGlobally: "Location Services are turned off for this device."
        case .restricted:     "Location access is restricted on this device."
        }
    }
}

/// What the location pipeline can report.
///
/// This deliberately carries more than a `Double`: a bare speed value cannot express
/// "denied" or "no signal", which is why every failure used to be invisible and the
/// UI could sit on ACQUIRING forever.
enum LocationEvent: Sendable {
    case speed(mps: Double, quality: SignalQuality)
    case noFix
    case stationary
    case waitingForAuthorization
    case accuracyLimited
    case notInUse
    case denied(DenialReason)
    case failed(any Error)
    case finished
}

// MARK: - Pure sample evaluation
//
// Kept free of CoreLocation types so it can be tested without GPS, in the same
// spirit as classify(_:min:max:) and shouldAnnounce(...) in PaceStatus.swift.

enum SampleDecision: Equatable {
    case accept(mps: Double, quality: SignalQuality)
    case reject
}

/// Widest horizontal accuracy (metres) still considered a usable fix.
///
/// Deliberately left loose. A previous tightening of the *speed* gate (see
/// `evaluateSample`) rejected almost everything on a real iPhone, and narrowing this one
/// risks the same failure. Accuracy comes from weighting samples by their uncertainty in
/// `fusedSpeed(_:)`, not from discarding them.
let maxUsableHorizontalAccuracy: Double = 50
/// Oldest a fix may be (seconds) before it is treated as stale/cached.
let maxUsableSampleAge: TimeInterval = 5
/// At or below this speed uncertainty (m/s) a sample is reported as `.good`.
let goodSpeedAccuracy: Double = 1.0
/// Above this speed uncertainty (m/s) a sample carries no usable information at all.
let maxUsableSpeedAccuracy: Double = 2.5

/// Decides whether a location sample yields a trustworthy speed.
///
/// The previous rule was `speedAccuracy < 1.0`, which rejects almost everything on a
/// real iPhone: 1.0 m/s is 3.6 km/h, an entire walking pace of tolerance. A negative
/// `speedAccuracy` means *unknown*, not *bad*, so it is accepted as degraded rather
/// than discarded.
func evaluateSample(
    speed: Double,
    speedAccuracy: Double,
    horizontalAccuracy: Double,
    age: TimeInterval
) -> SampleDecision {
    guard isUsableFix(horizontalAccuracy: horizontalAccuracy, age: age) else { return .reject }
    guard speed >= 0 else { return .reject }

    if speedAccuracy < 0 { return .accept(mps: speed, quality: .degraded) }
    if speedAccuracy <= goodSpeedAccuracy { return .accept(mps: speed, quality: .good) }
    if speedAccuracy <= maxUsableSpeedAccuracy { return .accept(mps: speed, quality: .degraded) }
    return .reject
}

/// Whether a fix is geometrically trustworthy, regardless of whether it carries a
/// speed solution. A fix can be usable for deriving speed even when its own `speed`
/// field is absent.
func isUsableFix(horizontalAccuracy: Double, age: TimeInterval) -> Bool {
    horizontalAccuracy >= 0
        && horizontalAccuracy <= maxUsableHorizontalAccuracy
        && abs(age) < maxUsableSampleAge
}

/// Speed derived from the distance between two consecutive fixes.
///
/// Used when a fix is otherwise good but carries no speed solution (`speed < 0`),
/// which is common in the first seconds of a run. Returns nil when the time delta is
/// too short to be meaningful or too long to be continuous.
func derivedSpeed(distance: Double, dt: TimeInterval) -> Double? {
    guard distance >= 0, dt >= 0.5, dt <= 10 else { return nil }
    return distance / dt
}

/// Decision for a fix that carries no native speed solution, deriving speed from the
/// previous usable fix instead.
///
/// The previous fix here must be the last *geometrically usable* one, not the last
/// accepted sample: at the start of a run several fixes in a row commonly arrive with
/// no speed solution, and keying off accepted samples would make this unreachable in
/// exactly the case it exists to handle.
func evaluateDerivedSample(
    speed: Double,
    horizontalAccuracy: Double,
    age: TimeInterval,
    distanceFromPrevious: Double,
    dtFromPrevious: TimeInterval
) -> SampleDecision {
    guard speed < 0 else { return .reject }
    guard isUsableFix(horizontalAccuracy: horizontalAccuracy, age: age) else { return .reject }
    guard let derived = derivedSpeed(distance: distanceFromPrevious, dt: dtFromPrevious) else { return .reject }
    return .accept(mps: derived, quality: .degraded)
}

// MARK: - Accuracy-weighted speed window
//
// The previous smoothing was an unweighted mean of the last 3 accepted samples. That
// gave a fix with +/-3 m/s of uncertainty the same vote as one with +/-0.3 m/s, which for
// a 10 km/h runner is a +/-100% error entering the average at full weight. Weighting by
// 1/sigma^2 keeps such a sample in the estimate (discarding it risks the documented
// "rejects almost everything" failure) while reducing its influence by an order of
// magnitude.

/// One accepted speed reading and how much to trust it.
///
/// `at` is *receipt* time (`Date.now`), not `loc.timestamp`: the window exists to answer
/// "how current is what the user is looking at", which is a wall-clock question.
struct SpeedSample: Sendable, Equatable {
    let mps: Double
    /// 1-sigma uncertainty in m/s.
    let sigma: Double
    let at: Date
}

/// Uncertainty attributed to a fix whose `speedAccuracy` is unknown (negative).
let unknownSpeedSigma: Double = 3.0
/// Floor on sigma, so one very confident sample cannot monopolise the weighted mean.
let minSpeedSigma: Double = 0.3

/// Uncertainty to attribute to a sample. A negative `speedAccuracy` means *unknown*,
/// which is treated as wide rather than discarded.
func speedSigma(speedAccuracy: Double) -> Double {
    guard speedAccuracy >= 0 else { return unknownSpeedSigma }
    return max(speedAccuracy, minSpeedSigma)
}

/// The samples falling inside the trailing window, oldest first.
///
/// This also subsumes gap handling: anything older than the window is dropped, so old
/// samples can never blend across a dropout.
func prune(_ samples: [SpeedSample], now: Date, window: TimeInterval) -> [SpeedSample] {
    samples.filter { now.timeIntervalSince($0.at) <= window }
}

/// Inverse-variance weighted mean of the window.
///
/// Quality is derived from the *median member* sigma, never from the fused sigma. Fused
/// sigma shrinks as 1/sqrt(n), so a 30 s window of thirty +/-1.5 m/s samples would fuse to
/// ~0.27 and report `.good` unconditionally — the LIVE/WEAK pill would stop meaning
/// anything at long windows. The fused *value* is right; only the label must stay
/// per-sample.
func fusedSpeed(_ samples: [SpeedSample]) -> (mps: Double, quality: SignalQuality)? {
    guard !samples.isEmpty else { return nil }

    var weightSum = 0.0
    var weightedSum = 0.0
    for sample in samples {
        let sigma = max(sample.sigma, minSpeedSigma)
        let weight = 1.0 / (sigma * sigma)
        weightSum += weight
        weightedSum += weight * sample.mps
    }
    guard weightSum > 0 else { return nil }

    let sigmas = samples.map { $0.sigma }.sorted()
    let median = sigmas[sigmas.count / 2]
    return (weightedSum / weightSum, median <= goodSpeedAccuracy ? .good : .degraded)
}

/// How long the readout may coast on the last accepted sample before it is zeroed.
///
/// Must scale with the window: a 30 s window under a fixed 5 s timeout would zero
/// constantly, and a 2 s window under a fixed 15 s one would leave the residual-speed
/// bug this exists to fix.
func stalenessTimeout(window: TimeInterval) -> TimeInterval {
    max(5, 1.5 * window)
}

/// Whether the displayed speed has gone stale and should fall back to zero.
func isStale(lastAcceptedAt: Date?, now: Date, window: TimeInterval) -> Bool {
    guard let last = lastAcceptedAt else { return false }
    return now.timeIntervalSince(last) > stalenessTimeout(window: window)
}
