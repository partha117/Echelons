import Testing
import Foundation
@testable import Echelons

// MARK: - SpeedUnit

struct SpeedUnitTests {
    @Test func testKphConversion() {
        #expect(abs(SpeedUnit.kph.convert(1.0) - 3.6) < 0.001)
    }

    @Test func testMphConversion() {
        #expect(abs(SpeedUnit.mph.convert(1.0) - 2.23694) < 0.001)
    }

    @Test func testZeroSpeed() {
        #expect(SpeedUnit.kph.convert(0.0) == 0.0)
    }

    @Test func testRoundTripKphToMph() {
        #expect(abs(SpeedUnit.mph.reexpress(3.6, from: .kph) - 2.23694) < 0.001)
    }

    @Test func testRoundTripMphToKph() {
        #expect(abs(SpeedUnit.kph.reexpress(2.23694, from: .mph) - 3.6) < 0.001)
    }

    @Test func testReexpressSameUnit() {
        #expect(SpeedUnit.kph.reexpress(10.0, from: .kph) == 10.0)
    }
}

// MARK: - Classification

struct ClassifyTests {
    @Test func testInRange() {
        #expect(classify(speed: 8.0, min: 6.0, max: 10.0) == .inRange)
    }

    @Test func testAtMinBoundary() {
        #expect(classify(speed: 6.0, min: 6.0, max: 10.0) == .inRange)
    }

    @Test func testAtMaxBoundary() {
        #expect(classify(speed: 10.0, min: 6.0, max: 10.0) == .inRange)
    }

    @Test func testBelowMin() {
        #expect(classify(speed: 4.0, min: 6.0, max: 10.0) == .tooSlow)
    }

    @Test func testAboveMax() {
        #expect(classify(speed: 12.0, min: 6.0, max: 10.0) == .tooFast)
    }

    @Test func testNarrowRange() {
        #expect(classify(speed: 7.0, min: 7.0, max: 7.0) == .inRange)
    }
}

// MARK: - Cadence Gating

struct CadenceGatingTests {
    @Test func testGateBlocksWhenTooSoon() {
        let last = Date()
        let now = last.addingTimeInterval(10)
        #expect(shouldAnnounce(status: .tooFast, lastAnnouncement: last, now: now, interval: 30) == false)
    }

    @Test func testGateAllowsWhenDue() {
        let last = Date()
        let now = last.addingTimeInterval(30)
        #expect(shouldAnnounce(status: .tooFast, lastAnnouncement: last, now: now, interval: 30) == true)
    }

    @Test func testGateSuppressesInRange() {
        let last = Date()
        let now = last.addingTimeInterval(60)
        #expect(shouldAnnounce(status: .inRange, lastAnnouncement: last, now: now, interval: 30) == false)
    }

    @Test func testGateBlocksTooSlowTooSoon() {
        let last = Date()
        let now = last.addingTimeInterval(5)
        #expect(shouldAnnounce(status: .tooSlow, lastAnnouncement: last, now: now, interval: 30) == false)
    }

    @Test func testGateAllowsTooSlowWhenDue() {
        let last = Date()
        let now = last.addingTimeInterval(31)
        #expect(shouldAnnounce(status: .tooSlow, lastAnnouncement: last, now: now, interval: 30) == true)
    }

    @Test func testGateFirstAnnouncement() {
        #expect(shouldAnnounce(status: .tooFast, lastAnnouncement: nil, now: .now, interval: 30) == true)
    }
}

// MARK: - PaceSettings Validation

struct PaceSettingsValidationTests {
    @Test func testValidRange() {
        let s = PaceSettings()
        s.minSpeed = 6.0
        s.maxSpeed = 10.0
        #expect(s.isValid == true)
    }

    @Test func testEqualBounds() {
        let s = PaceSettings()
        s.minSpeed = 7.0
        s.maxSpeed = 7.0
        #expect(s.isValid == false)
    }

    @Test func testInvertedRange() {
        let s = PaceSettings()
        s.minSpeed = 10.0
        s.maxSpeed = 6.0
        #expect(s.isValid == false)
    }

    @Test func testZeroMin() {
        let s = PaceSettings()
        s.minSpeed = 0.0
        s.maxSpeed = 5.0
        #expect(s.isValid == true)
    }
}

// MARK: - Sample Acceptance

struct SampleAcceptanceTests {
    private func accept(_ d: SampleDecision) -> Double? {
        if case let .accept(mps, _) = d { return mps }
        return nil
    }

    @Test func testGoodSampleAccepted() {
        let d = evaluateSample(speed: 3.0, speedAccuracy: 0.8, horizontalAccuracy: 10, age: 0)
        #expect(d == .accept(mps: 3.0, quality: .good))
    }

    // The old rule was speedAccuracy < 1.0, which rejected ordinary walking-pace fixes.
    @Test func testModerateAccuracyAcceptedAsDegraded() {
        let d = evaluateSample(speed: 2.0, speedAccuracy: 2.4, horizontalAccuracy: 20, age: 0)
        #expect(d == .accept(mps: 2.0, quality: .degraded))
    }

    @Test func testUnknownSpeedAccuracyIsAcceptedNotRejected() {
        let d = evaluateSample(speed: 2.0, speedAccuracy: -1, horizontalAccuracy: 20, age: 0)
        #expect(d == .accept(mps: 2.0, quality: .degraded))
    }

    @Test func testBoundaryBetweenGoodAndDegraded() {
        #expect(evaluateSample(speed: 1, speedAccuracy: 1.0, horizontalAccuracy: 10, age: 0)
            == .accept(mps: 1, quality: .good))
        #expect(evaluateSample(speed: 1, speedAccuracy: 1.1, horizontalAccuracy: 10, age: 0)
            == .accept(mps: 1, quality: .degraded))
    }

    @Test func testVeryImpreciseSpeedRejected() {
        #expect(evaluateSample(speed: 2.0, speedAccuracy: 2.6, horizontalAccuracy: 10, age: 0) == .reject)
    }

    @Test func testNegativeSpeedRejected() {
        #expect(evaluateSample(speed: -1, speedAccuracy: 0.5, horizontalAccuracy: 10, age: 0) == .reject)
    }

    @Test func testPoorHorizontalAccuracyRejected() {
        #expect(evaluateSample(speed: 2, speedAccuracy: 0.5, horizontalAccuracy: 51, age: 0) == .reject)
        #expect(evaluateSample(speed: 2, speedAccuracy: 0.5, horizontalAccuracy: -1, age: 0) == .reject)
    }

    @Test func testStaleSampleRejected() {
        #expect(evaluateSample(speed: 2, speedAccuracy: 0.5, horizontalAccuracy: 10, age: -6) == .reject)
    }
}

// MARK: - Derived Speed

struct DerivedSpeedTests {
    @Test func testDerivesSpeedFromDistanceOverTime() {
        #expect(derivedSpeed(distance: 10, dt: 2) == 5.0)
    }

    @Test func testRejectsTooShortInterval() {
        #expect(derivedSpeed(distance: 10, dt: 0.2) == nil)
    }

    @Test func testRejectsTooLongInterval() {
        #expect(derivedSpeed(distance: 10, dt: 11) == nil)
    }

    @Test func testAcceptsBoundaryIntervals() {
        #expect(derivedSpeed(distance: 1, dt: 0.5) == 2.0)
        #expect(derivedSpeed(distance: 10, dt: 10) == 1.0)
    }
}

// MARK: - Watchdog

struct WatchdogTests {
    @Test func testMovesToNoSignalWhenNothingAccepted() {
        #expect(watchdogSignal(current: .acquiring, hasAcceptedSample: false, elapsedSinceStart: 15) == .noSignal)
    }

    @Test func testStaysAcquiringBeforeThreshold() {
        #expect(watchdogSignal(current: .acquiring, hasAcceptedSample: false, elapsedSinceStart: 14) == .acquiring)
    }

    @Test func testDoesNotOverrideOnceSamplesArrived() {
        #expect(watchdogSignal(current: .acquiring, hasAcceptedSample: true, elapsedSinceStart: 60) == .acquiring)
    }

    @Test func testDoesNotOverrideExplicitDiagnostic() {
        #expect(watchdogSignal(current: .stationary, hasAcceptedSample: false, elapsedSinceStart: 60) == .stationary)
        #expect(watchdogSignal(current: .denied(.appDenied), hasAcceptedSample: false, elapsedSinceStart: 60)
            == .denied(.appDenied))
    }
}

// MARK: - Derived Sample Wiring
//
// Regression cover for the fallback being unreachable: it must fire on a fix with no
// speed solution given only a prior usable fix, with nothing accepted beforehand.

struct DerivedSampleTests {
    @Test func testFiresWhenNoNativeSpeedButPriorFixExists() {
        let d = evaluateDerivedSample(
            speed: -1, horizontalAccuracy: 12, age: 0,
            distanceFromPrevious: 6, dtFromPrevious: 2
        )
        #expect(d == .accept(mps: 3.0, quality: .degraded))
    }

    @Test func testDefersToNativeSpeedWhenPresent() {
        let d = evaluateDerivedSample(
            speed: 2.5, horizontalAccuracy: 12, age: 0,
            distanceFromPrevious: 6, dtFromPrevious: 2
        )
        #expect(d == .reject)
    }

    @Test func testRejectsWhenFixGeometryUnusable() {
        #expect(evaluateDerivedSample(
            speed: -1, horizontalAccuracy: 80, age: 0,
            distanceFromPrevious: 6, dtFromPrevious: 2) == .reject)
        #expect(evaluateDerivedSample(
            speed: -1, horizontalAccuracy: 12, age: -30,
            distanceFromPrevious: 6, dtFromPrevious: 2) == .reject)
    }

    @Test func testRejectsWhenIntervalOutOfRange() {
        #expect(evaluateDerivedSample(
            speed: -1, horizontalAccuracy: 12, age: 0,
            distanceFromPrevious: 6, dtFromPrevious: 0.1) == .reject)
    }
}

// MARK: - Usable Fix

struct UsableFixTests {
    @Test func testAcceptsFreshPreciseFix() {
        #expect(isUsableFix(horizontalAccuracy: 10, age: -1) == true)
    }

    @Test func testRejectsInvalidOrCoarseAccuracy() {
        #expect(isUsableFix(horizontalAccuracy: -1, age: 0) == false)
        #expect(isUsableFix(horizontalAccuracy: 51, age: 0) == false)
    }

    @Test func testRejectsStaleFix() {
        #expect(isUsableFix(horizontalAccuracy: 10, age: -6) == false)
    }
}


// MARK: - Speed Sigma

struct SpeedSigmaTests {
    @Test func testUnknownAccuracyGetsWideSigma() {
        #expect(speedSigma(speedAccuracy: -1) == unknownSpeedSigma)
    }

    @Test func testTinyAccuracyIsFloored() {
        #expect(speedSigma(speedAccuracy: 0.01) == minSpeedSigma)
    }

    @Test func testOrdinaryAccuracyPassesThrough() {
        #expect(speedSigma(speedAccuracy: 1.4) == 1.4)
    }
}

// MARK: - Window Pruning

struct PruneTests {
    private func sample(_ mps: Double, ageSeconds: TimeInterval, now: Date) -> SpeedSample {
        SpeedSample(mps: mps, sigma: 1.0, at: now.addingTimeInterval(-ageSeconds))
    }

    @Test func testDropsSamplesOlderThanWindow() {
        let now = Date()
        let kept = prune(
            [sample(1, ageSeconds: 12, now: now), sample(2, ageSeconds: 3, now: now)],
            now: now, window: 5
        )
        #expect(kept.count == 1)
        #expect(kept.first?.mps == 2)
    }

    @Test func testKeepsSampleAtExactWindowEdge() {
        let now = Date()
        #expect(prune([sample(1, ageSeconds: 5, now: now)], now: now, window: 5).count == 1)
    }

    @Test func testEmptyWindowFusesToNil() {
        let now = Date()
        let kept = prune([sample(1, ageSeconds: 60, now: now)], now: now, window: 5)
        #expect(fusedSpeed(kept) == nil)
    }
}

// MARK: - Weighted Fusion
//
// The regression guard for "speed is largely incorrect": the old unweighted mean gave a
// +/-3 m/s sample the same vote as a +/-0.3 m/s one.

struct FusedSpeedTests {
    @Test func testConfidentSampleDominatesUncertainOne() {
        let now = Date()
        let fused = fusedSpeed([
            SpeedSample(mps: 3.0, sigma: 0.3, at: now),
            SpeedSample(mps: 9.0, sigma: 3.0, at: now),
        ])
        #expect(fused != nil)
        // Unweighted this would be 6.0; weighted it stays near the trustworthy sample.
        #expect(abs((fused?.mps ?? 0) - 3.06) < 0.05)
    }

    @Test func testSingleSampleReturnsItself() {
        let fused = fusedSpeed([SpeedSample(mps: 4.2, sigma: 0.5, at: Date())])
        #expect(abs((fused?.mps ?? 0) - 4.2) < 0.001)
        #expect(fused?.quality == .good)
    }

    @Test func testEmptyReturnsNil() {
        #expect(fusedSpeed([]) == nil)
    }

    // Quality must come from the median member sigma, not the fused sigma: fused sigma
    // shrinks as 1/sqrt(n), so a long window of mediocre samples would otherwise always
    // report .good and the LIVE/WEAK pill would stop meaning anything.
    @Test func testLongWindowOfMediocreSamplesStaysDegraded() {
        let now = Date()
        let samples = (0..<30).map { SpeedSample(mps: 3.0, sigma: 1.5, at: now.addingTimeInterval(-Double($0))) }
        #expect(fusedSpeed(samples)?.quality == .degraded)
    }

    @Test func testLongWindowOfPreciseSamplesIsGood() {
        let now = Date()
        let samples = (0..<30).map { SpeedSample(mps: 3.0, sigma: 0.5, at: now.addingTimeInterval(-Double($0))) }
        #expect(fusedSpeed(samples)?.quality == .good)
    }
}

// MARK: - Staleness
//
// Cover for the residual-speed bug: the readout must not coast on the last moving value
// after the user stops. The threshold has to scale with the averaging window.

struct StalenessTests {
    @Test func testShortWindowUsesFloor() {
        #expect(stalenessTimeout(window: 2) == 5)
    }

    @Test func testLongWindowScales() {
        #expect(stalenessTimeout(window: 30) == 45)
    }

    @Test func testNoSampleIsNotStale() {
        #expect(isStale(lastAcceptedAt: nil, now: .now, window: 5) == false)
    }

    @Test func testRecentSampleIsNotStale() {
        let last = Date()
        #expect(isStale(lastAcceptedAt: last, now: last.addingTimeInterval(4), window: 5) == false)
    }

    @Test func testOldSampleIsStale() {
        let last = Date()
        #expect(isStale(lastAcceptedAt: last, now: last.addingTimeInterval(10), window: 5) == true)
    }

    @Test func testLongWindowToleratesLongerGap() {
        let last = Date()
        #expect(isStale(lastAcceptedAt: last, now: last.addingTimeInterval(20), window: 30) == false)
        #expect(isStale(lastAcceptedAt: last, now: last.addingTimeInterval(50), window: 30) == true)
    }
}
