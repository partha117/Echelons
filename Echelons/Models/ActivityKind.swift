import Foundation

enum ActivityKind: String, CaseIterable, Identifiable {
    case run, walk
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}
