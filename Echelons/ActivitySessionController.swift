import Foundation
import CoreLocation
import OSLog

@Observable
@MainActor
final class ActivitySessionController {
    private let log = Logger(subsystem: "runners.Echelons", category: "session")

    var isRunning = false
    var currentSpeed: Double = 0.0
    var status: PaceStatus = .acquiring
    var signal: SessionSignal = .acquiring
    var elapsed: TimeInterval = 0.0
    var authorizationStatus: CLAuthorizationStatus = .notDetermined

    let settings = PaceSettings()

    private let locationProvider: LocationSpeedProvider
    private let announcer: PaceAnnouncer
    private var streamTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var startTime: Date?
    private var lastAnnouncement: Date?
    private var hasAcceptedSample = false
    /// Receipt time of the last accepted speed, for the staleness backstop in startTimer().
    private var lastSpeedAt: Date?

    init() {
        locationProvider = LocationSpeedProvider()
        announcer = PaceAnnouncer()
        authorizationStatus = locationProvider.currentAuthorizationStatus
        locationProvider.onAuthorizationChange = { [weak self] status in
            self?.authorizationStatus = status
        }
    }

    func start(kind: ActivityKind = .run) {
        guard !isRunning else { return }

        isRunning = true
        status = .acquiring
        signal = .acquiring
        startTime = .now
        lastAnnouncement = nil
        elapsed = 0.0
        lastSpeedAt = nil
        hasAcceptedSample = false
        locationProvider.speedWindow = settings.speedWindow

        startTimer()
        startWatchdog()

        streamTask = Task { [weak self] in
            guard let self else { return }

            // 1. Resolve authorization first, awaiting the user's answer. Racing ahead
            //    would leave us backgrounded by the time the session is created.
            let status = await self.locationProvider.requestAuthorization()
            self.authorizationStatus = status

            guard status == .authorizedWhenInUse || status == .authorizedAlways else {
                self.log.error("authorization not granted: \(status.rawValue, privacy: .public)")
                self.finish(with: status == .restricted ? .denied(.restricted) : .denied(.appDenied))
                return
            }
            guard !Task.isCancelled else { return }

            // 2. Still foreground here, which is the SDK's requirement for the session
            //    to become active, and for the audio category to be set before any
            //    announcement happens in the background.
            self.locationProvider.beginBackgroundSession()
            self.announcer.prepare()

            // 3. Only now start consuming updates.
            for await event in self.locationProvider.events() {
                if Task.isCancelled { break }
                self.handle(event)
            }

            // Terminal path: the stream ending must never leave the UI mid-run.
            if self.isRunning {
                self.log.notice("event stream ended while running")
                self.finish(with: self.signal == .acquiring ? .noSignal : self.signal)
            }
        }
    }

    func stop() {
        streamTask?.cancel()
        timerTask?.cancel()
        watchdogTask?.cancel()
        streamTask = nil
        timerTask = nil
        watchdogTask = nil
        locationProvider.endBackgroundSession()
        announcer.stop()
        isRunning = false
        status = .acquiring
        signal = .acquiring
        currentSpeed = 0.0
        elapsed = 0.0
        startTime = nil
        lastAnnouncement = nil
        lastSpeedAt = nil
        hasAcceptedSample = false
    }

    // MARK: - Event handling

    private func handle(_ event: LocationEvent) {
        switch event {
        case let .speed(mps, quality):
            hasAcceptedSample = true
            lastSpeedAt = .now
            signal = quality == .good ? .live : .weak
            let converted = settings.unit.convert(mps)
            currentSpeed = converted
            status = classify(speed: converted, min: settings.minSpeed, max: settings.maxSpeed)
            announceIfDue(converted)

        case .noFix:
            if hasAcceptedSample { signal = .weak }

        case .stationary:
            // The readout used to keep the last moving value here, so stopping for a
            // minute still displayed a pace. status is .acquiring rather than
            // classify(0, ...) == .tooSlow deliberately: shouldAnnounce() ignores
            // .acquiring, so a stopped user is not nagged to speed up.
            signal = .stationary
            currentSpeed = 0.0
            status = .acquiring
            // lastSpeedAt is deliberately left alone: it arms the staleness backstop in
            // startTimer(), and isStale() treats nil as "not stale". Clearing it here
            // would disarm the backstop for the rest of the run.

        case .waitingForAuthorization:
            signal = .acquiring

        case .accuracyLimited:
            finish(with: .accuracyLimited)

        case .notInUse:
            signal = .notInUse

        case let .denied(reason):
            finish(with: .denied(reason))

        case let .failed(error):
            log.error("location stream failed: \(error.localizedDescription, privacy: .public)")
            finish(with: .noSignal)

        case .finished:
            finish(with: hasAcceptedSample ? signal : .noSignal)
        }
    }

    private func announceIfDue(_ speed: Double) {
        guard shouldAnnounce(
            status: status,
            lastAnnouncement: lastAnnouncement,
            now: .now,
            interval: settings.checkInterval
        ) else { return }

        // Only restart the cadence clock when speech was actually enqueued; stamping
        // it on a skipped announcement would silently stretch the interval.
        if announcer.announce(speed: speed, unit: settings.unit, status: status) {
            lastAnnouncement = .now
        }
    }

    /// Ends the run, leaving a signal the UI can explain.
    private func finish(with signal: SessionSignal) {
        self.signal = signal
        isRunning = false
        currentSpeed = 0.0
        status = .acquiring
        lastSpeedAt = nil
        timerTask?.cancel(); timerTask = nil
        watchdogTask?.cancel(); watchdogTask = nil
        locationProvider.endBackgroundSession()
        announcer.stop()
    }

    // MARK: - Background tasks

    private func startTimer() {
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, let start = self.startTime else { break }
                let now = Date.now
                self.elapsed = now.timeIntervalSince(start)
                // Cheap enough to just re-push, and it makes a mid-run slider change live.
                self.locationProvider.speedWindow = self.settings.speedWindow

                // Backstop for a stalled pipeline: CoreLocation's stationary flag can lag
                // or never fire. Deliberately checked here rather than on .noFix, which is
                // also yielded for every individually rejected sample and would flash the
                // readout to zero and back mid-run.
                if isStale(lastAcceptedAt: self.lastSpeedAt, now: now, window: self.settings.speedWindow) {
                    self.currentSpeed = 0.0
                    self.status = .acquiring
                    self.signal = .weak
                }
            }
        }
    }

    /// Backstop against a silently stalled pipeline: if nothing usable arrives within
    /// the watchdog interval, say so rather than sitting on ACQUIRING forever.
    private func startWatchdog() {
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(acquiringWatchdogInterval))
            guard !Task.isCancelled, let self, let start = self.startTime else { return }
            self.signal = watchdogSignal(
                current: self.signal,
                hasAcceptedSample: self.hasAcceptedSample,
                elapsedSinceStart: Date.now.timeIntervalSince(start)
            )
        }
    }
}
