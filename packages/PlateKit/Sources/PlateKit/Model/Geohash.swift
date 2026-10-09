import Foundation

/// Base-32 geohash encoding (public-domain algorithm). Precision 6
/// (~610 m × 610 m) is our sharing granularity — the default public view of
/// any sighting.
public enum Geohash {
    private static let alphabet = Array("0123456789bcdefghjkmnpqrstuvwxyz")

    /// Encode latitude/longitude at `precision` characters.
    public static func encode(latitude: Double, longitude: Double, precision: Int = 6) -> String {
        var latRange = (-90.0, 90.0)
        var lonRange = (-180.0, 180.0)
        var hash = ""
        hash.reserveCapacity(precision)
        var isLon = true
        var bit = 0
        var value = 0

        while hash.count < precision {
            if isLon {
                let mid = (lonRange.0 + lonRange.1) / 2
                if longitude >= mid { value = (value << 1) | 1; lonRange.0 = mid }
                else { value <<= 1; lonRange.1 = mid }
            } else {
                let mid = (latRange.0 + latRange.1) / 2
                if latitude >= mid { value = (value << 1) | 1; latRange.0 = mid }
                else { value <<= 1; latRange.1 = mid }
            }
            isLon.toggle()
            bit += 1
            if bit == 5 {
                hash.append(alphabet[value])
                bit = 0
                value = 0
            }
        }
        return hash
    }

    /// Center of the cell for a hash (for approximate map display only —
    /// never stored on fleet-confirmed records, which carry exact geo).
    public static func decodeCenter(_ hash: String) -> (latitude: Double, longitude: Double)? {
        var latRange = (-90.0, 90.0)
        var lonRange = (-180.0, 180.0)
        var isLon = true
        for char in hash.lowercased() {
            guard let idx = alphabet.firstIndex(of: char) else { return nil }
            for bitIndex in stride(from: 4, through: 0, by: -1) {
                let bit = (idx >> bitIndex) & 1
                if isLon {
                    let mid = (lonRange.0 + lonRange.1) / 2
                    if bit == 1 { lonRange.0 = mid } else { lonRange.1 = mid }
                } else {
                    let mid = (latRange.0 + latRange.1) / 2
                    if bit == 1 { latRange.0 = mid } else { latRange.1 = mid }
                }
                isLon.toggle()
            }
        }
        return ((latRange.0 + latRange.1) / 2, (lonRange.0 + lonRange.1) / 2)
    }
}

public extension GeoBucket {
    /// Convenience: bucket from precise coordinates (exact is attached only
    /// by the fleet-confirm path, not here).
    init(latitude: Double, longitude: Double) {
        self.init(geohash6: Geohash.encode(latitude: latitude, longitude: longitude))
    }
}
