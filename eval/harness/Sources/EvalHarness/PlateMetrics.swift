import Foundation
import PlateKit

/// OCR metrics used by the offline evaluation harness. These operate only on
/// labelled evaluation images and never enter the capture or sync paths.
enum PlateMetrics {
    static func normalized(_ value: String) -> String {
        Plate.normalize(value)
    }

    static func characterErrorRate(expected: String, actual: String) -> Double {
        let lhs = Array(normalized(expected))
        let rhs = Array(normalized(actual))
        guard !lhs.isEmpty else { return rhs.isEmpty ? 0 : 1 }
        var previous = Array(0...rhs.count)
        for (i, character) in lhs.enumerated() {
            var current = [i + 1]
            current.reserveCapacity(rhs.count + 1)
            for (j, other) in rhs.enumerated() {
                let substitution = previous[j] + (character == other ? 0 : 1)
                current.append(min(substitution, current[j] + 1, previous[j + 1] + 1))
            }
            previous = current
        }
        return Double(previous[rhs.count]) / Double(lhs.count)
    }
}
