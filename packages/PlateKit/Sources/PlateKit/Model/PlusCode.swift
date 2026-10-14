import Foundation

/// Open Location Code ("Plus Code") decoding — enough to turn a code a person pastes from Google Maps into a point.
/// Supports full codes ("849VCWC8+R9"), grid-refined codes, and short codes ("CWC8+R9") recovered against a nearby
/// reference position. Encoding is limited to what short-code recovery needs.
public enum PlusCode {
    private static let alphabet = Array("23456789CFGHJMPQRVWX")
    private static let separatorPosition = 8
    private static let separator: Character = "+"
    private static let padding: Character = "0"

    public struct Area: Sendable, Equatable {
        public var latitude: Double, longitude: Double      // centre
        public var latitudeSize: Double, longitudeSize: Double
    }

    /// Decodes a full code; nil when the code is malformed or short.
    public static func decode(_ input: String) -> Area? {
        let code = input.trimmingCharacters(in: .whitespaces).uppercased()
        guard isFull(code) else { return nil }
        let digits = code.filter { $0 != separator && $0 != padding }.map { $0 }
        guard digits.count >= 2 else { return nil }
        var lat = -90.0, lon = -180.0
        var latRes = 20.0, lonRes = 20.0
        var i = 0
        while i < min(digits.count, 10) {
            guard let a = alphabet.firstIndex(of: digits[i]) else { return nil }
            lat += Double(a) * latRes
            if i + 1 < min(digits.count, 10) {
                guard let b = alphabet.firstIndex(of: digits[i + 1]) else { return nil }
                lon += Double(b) * lonRes
            }
            if i + 2 < min(digits.count, 10) || digits.count > 10 { latRes /= 20; lonRes /= 20 }
            i += 2
        }
        let pairs = min(digits.count, 10) / 2
        var latSize = pow(20.0, Double(2 - pairs)), lonSize = latSize
        if digits.count > 10 {
            var rowH = latSize, colW = lonSize
            for ch in digits[10...] {
                guard let d = alphabet.firstIndex(of: ch) else { return nil }
                rowH /= 5; colW /= 4
                lat += Double(d / 4) * rowH
                lon += Double(d % 4) * colW
            }
            latSize = rowH; lonSize = colW
        }
        return Area(latitude: lat + latSize / 2, longitude: lon + lonSize / 2, latitudeSize: latSize, longitudeSize: lonSize)
    }

    public static func isShort(_ input: String) -> Bool {
        let code = input.trimmingCharacters(in: .whitespaces).uppercased()
        guard let idx = code.firstIndex(of: separator) else { return false }
        return code.distance(from: code.startIndex, to: idx) < separatorPosition && validChars(code)
    }

    /// Recovers a short code's full position using a reference point (e.g. the town you are in). Returns the area centre.
    public static func decodeShort(_ input: String, nearLatitude refLat: Double, longitude refLon: Double) -> Area? {
        let code = input.trimmingCharacters(in: .whitespaces).uppercased()
        guard isShort(code), let sep = code.firstIndex(of: separator) else { return nil }
        let before = code.distance(from: code.startIndex, to: sep)
        let prefixLen = separatorPosition - before
        guard prefixLen > 0, prefixLen % 2 == 0 else { return nil }
        let prefix = String(encodePairs(latitude: refLat, longitude: refLon).prefix(prefixLen))
        guard var area = decode(prefix + code) else { return nil }
        let resolution = pow(20.0, Double(2 - prefixLen / 2))
        let half = resolution / 2
        if refLat + half < area.latitude - 0 && area.latitude - resolution >= -90 && abs(area.latitude - refLat) > half { area.latitude -= resolution }
        else if abs(area.latitude - refLat) > half && area.latitude + resolution <= 90 && refLat > area.latitude { area.latitude += resolution }
        if refLon + half < area.longitude && abs(area.longitude - refLon) > half { area.longitude -= resolution }
        else if abs(area.longitude - refLon) > half && refLon > area.longitude { area.longitude += resolution }
        return area
    }

    private static func isFull(_ code: String) -> Bool {
        guard validChars(code), let idx = code.firstIndex(of: separator),
              code.distance(from: code.startIndex, to: idx) == separatorPosition, code.filter({ $0 == separator }).count == 1 else { return false }
        // First pair: latitude digit ≤ 'F' (index 9 → 180°), longitude digit ≤ 'V'.
        let chars = Array(code)
        guard let la = alphabet.firstIndex(of: chars[0]), la <= 8 else { return false }
        if let lo = alphabet.firstIndex(of: chars[1]), lo > 17 { return false }
        return true
    }

    private static func validChars(_ code: String) -> Bool {
        code.allSatisfy { $0 == separator || $0 == padding || alphabet.contains($0) }
    }

    /// The first ten digits (five lat/lon pairs), no separator.
    static func encodePairs(latitude: Double, longitude: Double) -> String {
        var lat = min(max(latitude, -90), 90 - 1e-9) + 90
        var lon = longitude
        while lon < -180 { lon += 360 }
        while lon >= 180 { lon -= 360 }
        lon += 180
        var out = "", res = 20.0
        for _ in 0..<5 {
            let la = min(Int(lat / res), 19), lo = min(Int(lon / res), 19)
            out.append(alphabet[la]); out.append(alphabet[lo])
            lat -= Double(la) * res; lon -= Double(lo) * res
            res /= 20
        }
        return out
    }
}
