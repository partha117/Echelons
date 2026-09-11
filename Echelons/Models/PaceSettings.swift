import Foundation

@Observable
final class PaceSettings {
    var minSpeed: Double = 6.0 {
        didSet { UserDefaults.standard.set(minSpeed, forKey: "pace.minSpeed") }
    }
    var maxSpeed: Double = 10.0 {
        didSet { UserDefaults.standard.set(maxSpeed, forKey: "pace.maxSpeed") }
    }
    var unit: SpeedUnit = .kph {
        didSet { UserDefaults.standard.set(unit.rawValue, forKey: "pace.unit") }
    }
    var checkInterval: Double = 30.0 {
        didSet { UserDefaults.standard.set(checkInterval, forKey: "pace.checkInterval") }
    }
    /// Seconds of GPS samples fused into the displayed speed. Longer is steadier but
    /// slower to react. Not a GPS sampling rate — CLLocationUpdate.liveUpdates exposes
    /// no such knob; this is a client-side averaging window.
    var speedWindow: Double = 5.0 {
        didSet { UserDefaults.standard.set(speedWindow, forKey: "pace.speedWindow") }
    }

    init() {
        if let v = UserDefaults.standard.object(forKey: "pace.minSpeed") as? Double { minSpeed = v }
        if let v = UserDefaults.standard.object(forKey: "pace.maxSpeed") as? Double { maxSpeed = v }
        if let raw = UserDefaults.standard.string(forKey: "pace.unit"),
           let u = SpeedUnit(rawValue: raw) { unit = u }
        if let v = UserDefaults.standard.object(forKey: "pace.checkInterval") as? Double { checkInterval = v }
        if let v = UserDefaults.standard.object(forKey: "pace.speedWindow") as? Double { speedWindow = v }
    }

    var isValid: Bool { minSpeed < maxSpeed }
}
