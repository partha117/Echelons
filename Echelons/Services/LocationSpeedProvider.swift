import CoreLocation
import OSLog

@MainActor
final class LocationSpeedProvider: NSObject, CLLocationManagerDelegate {
    private let log = Logger(subsystem: "runners.Echelons", category: "location")

    // Retained only for authorization: requestWhenInUseAuthorization(), authorizationStatus,
    // and the delegate callback. startUpdatingLocation() is deliberately never called —
    // CLLocationUpdate.liveUpdates() is a separate pipeline that reads none of this
    // manager's configuration. desiredAccuracy, distanceFilter, activityType,
    // pausesLocationUpdatesAutomatically, allowsBackgroundLocationUpdates and
    // showsBackgroundLocationIndicator were set here previously and had no effect at all;
    // do not re-add them. Background eligibility comes from CLBackgroundActivitySession.
    private let manager = CLLocationManager()

    private var backgroundSession: CLBackgroundActivitySession?
    private var diagnosticsTask: Task<Void, Never>?
    private var authContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?

    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?

    /// Seconds of samples fused into each emitted speed. Read fresh on every update so a
    /// mid-run change in Settings takes effect immediately.
    var speedWindow: TimeInterval = 5.0

    override init() {
        super.init()
        manager.delegate = self
    }

    deinit {
        diagnosticsTask?.cancel()
        backgroundSession?.invalidate()
    }

    var currentAuthorizationStatus: CLAuthorizationStatus {
        manager.authorizationStatus
    }

    // MARK: - Authorization

    /// Requests When-In-Use authorization and suspends until the user answers.
    ///
    /// Awaiting the answer (rather than racing ahead into the update stream) is what
    /// guarantees the app is still foreground when `beginBackgroundSession()` runs —
    /// a CLBackgroundActivitySession only becomes active if created "while the app is
    /// foregrounded and in direct use".
    func requestAuthorization() async -> CLAuthorizationStatus {
        let status = manager.authorizationStatus
        guard status == .notDetermined else { return status }

        return await withCheckedContinuation { continuation in
            // The delegate can fire more than once; only the first resumes.
            authContinuation = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.log.notice("authorization changed: \(status.rawValue, privacy: .public)")
            self.onAuthorizationChange?(status)
            if status != .notDetermined, let continuation = self.authContinuation {
                self.authContinuation = nil
                continuation.resume(returning: status)
            }
        }
    }

    // MARK: - Background activity session

    /// Must be called while foreground, after authorization is granted, or the session
    /// is created inactive and every update reports `insufficientlyInUse`.
    func beginBackgroundSession() {
        guard backgroundSession == nil else { return }
        let session = CLBackgroundActivitySession()
        backgroundSession = session
        log.notice("background activity session started")

        diagnosticsTask = Task { [weak self] in
            do {
                for try await diagnostic in session.diagnostics {
                    guard let self else { return }
                    self.log.warning("""
                        session diagnostic: denied=\(diagnostic.authorizationDenied, privacy: .public) \
                        deniedGlobally=\(diagnostic.authorizationDeniedGlobally, privacy: .public) \
                        restricted=\(diagnostic.authorizationRestricted, privacy: .public) \
                        insufficientlyInUse=\(diagnostic.insufficientlyInUse, privacy: .public) \
                        serviceSessionRequired=\(diagnostic.serviceSessionRequired, privacy: .public) \
                        authRequestInProgress=\(diagnostic.authorizationRequestInProgress, privacy: .public)
                        """)
                }
            } catch {
                self?.log.error("session diagnostics ended: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Ends the session and removes the blue status indicator.
    func endBackgroundSession() {
        diagnosticsTask?.cancel()
        diagnosticsTask = nil
        backgroundSession?.invalidate()
        backgroundSession = nil
        log.notice("background activity session invalidated")
    }

    // MARK: - Speed stream

    func events() -> AsyncStream<LocationEvent> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                await self?.pump(into: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func pump(into continuation: AsyncStream<LocationEvent>.Continuation) async {
        var samples: [SpeedSample] = []
        // Tracked separately from acceptance: a fix with no speed solution is still a
        // valid anchor for deriving speed from the next one.
        var lastFix: CLLocation?

        do {
            for try await update in CLLocationUpdate.liveUpdates(.fitness) {
                if Task.isCancelled { break }

                if let event = Self.terminalEvent(for: update) {
                    log.error("terminal diagnostic: \(String(describing: event), privacy: .public)")
                    continuation.yield(event)
                    continuation.finish()
                    return
                }

                if update.authorizationRequestInProgress {
                    continuation.yield(.waitingForAuthorization)
                    continue
                }
                if update.insufficientlyInUse {
                    // Signature of a background session that never became active.
                    log.error("insufficientlyInUse — background session is not active")
                    continuation.yield(.notInUse)
                    continue
                }
                if update.stationary {
                    continuation.yield(.stationary)
                    continue
                }

                guard let loc = update.location else {
                    log.debug("update with no location (locationUnavailable=\(update.locationUnavailable, privacy: .public))")
                    continuation.yield(.noFix)
                    continue
                }

                let now = Date.now
                let windowLength = speedWindow

                // prune() already prevents blending across a dropout, but lastFix is the
                // anchor for derived speed and must not survive one.
                samples = prune(samples, now: now, window: windowLength)
                if let previous = lastFix,
                   now.timeIntervalSince(previous.timestamp) > stalenessTimeout(window: windowLength) {
                    lastFix = nil
                }

                log.debug("""
                    fix speed=\(loc.speed, format: .fixed(precision: 2), privacy: .public) \
                    speedAcc=\(loc.speedAccuracy, format: .fixed(precision: 2), privacy: .public) \
                    horizAcc=\(loc.horizontalAccuracy, format: .fixed(precision: 1), privacy: .public) \
                    age=\(abs(loc.timestamp.timeIntervalSinceNow), format: .fixed(precision: 2), privacy: .public)
                    """)

                let age = loc.timestamp.timeIntervalSinceNow
                var decision = evaluateSample(
                    speed: loc.speed,
                    speedAccuracy: loc.speedAccuracy,
                    horizontalAccuracy: loc.horizontalAccuracy,
                    age: age
                )

                // No speed solution but an otherwise good fix: derive it from the last
                // usable fix. Common in the first seconds of a run, which is why the
                // anchor is lastFix rather than the last accepted sample.
                var usedDerived = false
                if case .reject = decision, let previous = lastFix {
                    usedDerived = true
                    decision = evaluateDerivedSample(
                        speed: loc.speed,
                        horizontalAccuracy: loc.horizontalAccuracy,
                        age: age,
                        distanceFromPrevious: loc.distance(from: previous),
                        dtFromPrevious: loc.timestamp.timeIntervalSince(previous.timestamp)
                    )
                }

                if isUsableFix(horizontalAccuracy: loc.horizontalAccuracy, age: age) {
                    lastFix = loc
                }

                // The per-sample quality label is not used here: the emitted quality comes
                // from fusedSpeed(), which judges the whole window.
                guard case let .accept(mps, _) = decision else {
                    continuation.yield(.noFix)
                    continue
                }

                // A derived sample has no speed solution of its own, so the fix's
                // speedAccuracy describes nothing and must not be read. Keyed off the code
                // path rather than inferred from loc.speed < 0, which the SDK does not
                // promise to pair with a meaningless speedAccuracy.
                let sigma = usedDerived
                    ? unknownSpeedSigma
                    : speedSigma(speedAccuracy: loc.speedAccuracy)
                samples.append(SpeedSample(mps: mps, sigma: sigma, at: now))

                guard let fused = fusedSpeed(samples) else {
                    continuation.yield(.noFix)
                    continue
                }
                continuation.yield(.speed(mps: fused.mps, quality: fused.quality))
            }
            log.notice("live updates ended")
            continuation.yield(.finished)
        } catch {
            log.error("live updates failed: \(error.localizedDescription, privacy: .public)")
            continuation.yield(.failed(error))
        }
        continuation.finish()
    }

    private static func terminalEvent(for update: CLLocationUpdate) -> LocationEvent? {
        if update.authorizationDeniedGlobally { return .denied(.deniedGlobally) }
        if update.authorizationRestricted { return .denied(.restricted) }
        if update.authorizationDenied { return .denied(.appDenied) }
        if update.accuracyLimited { return .accuracyLimited }
        return nil
    }
}
