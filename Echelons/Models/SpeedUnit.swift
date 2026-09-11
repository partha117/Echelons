import Foundation

enum SpeedUnit: String, CaseIterable, Identifiable {
    case kph, mph

    var id: String { rawValue }
    var label: String { rawValue.uppercased() }

    func convert(_ metersPerSecond: Double) -> Double {
        switch self {
        case .kph: metersPerSecond * 3.6
        case .mph: metersPerSecond * 2.23694
        }
    }

    // Re-express a threshold value when the user switches units.
    // Converts `value` (in `source` unit) to the same physical speed in `self`.
    func reexpress(_ value: Double, from source: SpeedUnit) -> Double {
        let mps = source == .kph ? value / 3.6 : value / 2.23694
        return convert(mps)
    }
}
