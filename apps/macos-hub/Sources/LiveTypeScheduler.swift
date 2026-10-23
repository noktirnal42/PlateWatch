import Foundation
import PlateKit

/// Ephemeral display-only association and fair inference budget for one Live session.
/// No frames, plate text, fleet verdicts or cross-camera identities are retained.
struct LiveTypeScheduler: Sendable {
    struct Assignment: Sendable { let index: Int; let track: Int }
    struct Plan: Sendable { let assignments: [Assignment]; let requests: [Assignment] }
    private struct Track: Sendable {
        let id: Int
        var box: NormalizedBox
        var seed: String?
        let firstSeen: TimeInterval
        var lastSeen: TimeInterval
        var attempted: TimeInterval?
        var body: String?
        var classified: TimeInterval?
    }
    static let budget = 4
    static let cooldown: TimeInterval = 2
    static let lifetime: TimeInterval = 5
    static let cacheLifetime: TimeInterval = 3
    static let capacity = 64
    private var tracks: [Track] = []
    private var nextID = 0
    private var lastTime: TimeInterval?
    var count: Int { tracks.count }

    mutating func prepare(_ vehicles: [VehicleObservation], imageSize: CGSize, now: TimeInterval) -> Plan {
        if let lastTime, now < lastTime { tracks = [] }
        lastTime = now
        tracks.removeAll { now - $0.lastSeen > Self.lifetime }
        var candidates: [(overlap: Double, track: Int, index: Int)] = []
        for (t, track) in tracks.enumerated() {
            for (i, vehicle) in vehicles.enumerated() {
                let overlap = Self.iou(track.box, vehicle.boundingBox)
                if overlap >= (track.seed == vehicle.attributes?.bodyType ? 0.4 : 0.65) {
                    candidates.append((overlap, t, i))
                }
            }
        }
        candidates.sort {
            if $0.overlap != $1.overlap { return $0.overlap > $1.overlap }
            if $0.track != $1.track { return $0.track < $1.track }
            return $0.index < $1.index
        }
        var matched: [Int: Int] = [:]
        var used: Set<Int> = []
        for c in candidates where matched[c.index] == nil && !used.contains(c.track) {
            matched[c.index] = c.track; used.insert(c.track)
        }
        var assignments: [Assignment] = []
        for (index, vehicle) in vehicles.enumerated() {
            let t: Int
            if let match = matched[index] { t = match }
            else {
                // Bound metadata; excess crops keep their original display attributes.
                guard tracks.count < Self.capacity else { continue }
                t = tracks.count
                tracks.append(Track(id: nextID, box: vehicle.boundingBox, seed: vehicle.attributes?.bodyType,
                                    firstSeen: now, lastSeen: now))
                nextID += 1
            }
            if tracks[t].seed != vehicle.attributes?.bodyType {
                tracks[t].body = nil; tracks[t].classified = nil; tracks[t].attempted = nil
            }
            tracks[t].box = vehicle.boundingBox
            tracks[t].seed = vehicle.attributes?.bodyType
            tracks[t].lastSeen = now
            assignments.append(.init(index: index, track: tracks[t].id))
        }
        let eligible = assignments.filter { item in
            guard let track = tracks.first(where: { $0.id == item.track }) else { return false }
            let box = vehicles[item.index].boundingBox
            let width = max(0, min(1, box.x + box.width) - max(0, box.x)) * imageSize.width
            let height = max(0, min(1, box.y + box.height) - max(0, box.y)) * imageSize.height
            return (track.seed == nil || track.seed == "car") && width + 1e-9 >= 48 && height + 1e-9 >= 48
                && (track.attempted.map { now - $0 >= Self.cooldown } ?? true)
        }.sorted { a, b in
            let ta = tracks.first { $0.id == a.track }!, tb = tracks.first { $0.id == b.track }!
            let pa = ta.attempted ?? (ta.firstSeen - Self.cooldown)
            let pb = tb.attempted ?? (tb.firstSeen - Self.cooldown)
            return pa == pb ? ta.id < tb.id : pa < pb
        }
        let requests = Array(eligible.prefix(Self.budget))
        for item in requests {
            if let t = tracks.firstIndex(where: { $0.id == item.track }) { tracks[t].attempted = now }
        }
        return Plan(assignments: assignments, requests: requests)
    }

    mutating func record(_ body: String?, track: Int, now: TimeInterval) {
        guard let t = tracks.firstIndex(where: { $0.id == track }) else { return }
        tracks[t].body = body
        tracks[t].classified = body == nil ? nil : now
    }

    func body(for track: Int, now: TimeInterval) -> String? {
        guard let t = tracks.first(where: { $0.id == track }), let classified = t.classified,
              now >= classified, now - classified <= Self.cacheLifetime else { return nil }
        return t.body
    }

    private static func iou(_ a: NormalizedBox, _ b: NormalizedBox) -> Double {
        let overlap = max(0, min(a.x + a.width, b.x + b.width) - max(a.x, b.x))
            * max(0, min(a.y + a.height, b.y + b.height) - max(a.y, b.y))
        let union = a.width * a.height + b.width * b.height - overlap
        return union > 0 ? overlap / union : 0
    }
}
