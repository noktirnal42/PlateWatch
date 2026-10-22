import Foundation
import PlateKit

/// Follows overlay boxes across the ~1 fps analysed frames of one Live feed so a box keeps its identity and its label stops
/// flickering between "Blue Car" and "Blue Truck" from one frame to the next (pattern from TrafficView's IoU tracker + vote
/// tally, re-implemented and much smaller). It only smooths the *display* label. Whether a box is a fleet hit always comes from
/// the current frame's gate verdict — a stale vote can never turn a vehicle into a fleet hit or hide one.
struct LiveBoxTracker {
    struct Detection {
        var rect: NormalizedBox
        var label: String
        var isFleet: Bool
        var uncertain: Bool
    }

    struct Tracked {
        var id: UUID
        var rect: NormalizedBox
        var label: String
        var isFleet: Bool
        var uncertain: Bool
        /// Frames this vehicle has been followed (1 on first sight).
        var hits: Int
    }

    static let matchIoU = 0.3
    static let maxMisses = 3
    static let voteWindow = 7

    private struct Track {
        var id = UUID()
        var rect: NormalizedBox
        var votes: [String] = []
        var hits = 1
        var misses = 0
    }
    private var tracks: [Track] = []

    mutating func reset() { tracks = [] }

    mutating func update(_ detections: [Detection]) -> [Tracked] {
        var candidates: [(iou: Double, track: Int, detection: Int)] = []
        for (t, track) in tracks.enumerated() {
            for (d, detection) in detections.enumerated() {
                let overlap = Self.iou(track.rect, detection.rect)
                if overlap >= Self.matchIoU { candidates.append((overlap, t, d)) }
            }
        }
        candidates.sort { ($0.iou, $1.track, $1.detection) > ($1.iou, $0.track, $0.detection) }
        var trackFor: [Int: Int] = [:]
        var taken = Set<Int>()
        for c in candidates where trackFor[c.detection] == nil && !taken.contains(c.track) {
            trackFor[c.detection] = c.track; taken.insert(c.track)
        }
        for index in tracks.indices where !taken.contains(index) { tracks[index].misses += 1 }

        var out: [Tracked] = []
        for (d, detection) in detections.enumerated() {
            let t: Int
            if let matched = trackFor[d] {
                t = matched
                tracks[t].rect = detection.rect
                tracks[t].misses = 0
                tracks[t].hits += 1
            } else {
                tracks.append(Track(rect: detection.rect)); t = tracks.count - 1
            }
            let parts = detection.label.components(separatedBy: " · ")
            tracks[t].votes.append(parts.first ?? detection.label)
            if tracks[t].votes.count > Self.voteWindow { tracks[t].votes.removeFirst(tracks[t].votes.count - Self.voteWindow) }
            let base = Self.winner(tracks[t].votes)
            let label = ([base] + parts.dropFirst()).joined(separator: " · ")
            out.append(Tracked(id: tracks[t].id, rect: detection.rect, label: label, isFleet: detection.isFleet,
                               uncertain: detection.uncertain && base.hasPrefix("Vehicle"), hits: tracks[t].hits))
        }
        tracks.removeAll { $0.misses > Self.maxMisses }
        return out
    }

    /// Most frequent vote; on a tie the most recent of the tied values.
    static func winner(_ votes: [String]) -> String {
        var counts: [String: Int] = [:]
        for v in votes { counts[v, default: 0] += 1 }
        let best = counts.values.max() ?? 0
        return votes.last { counts[$0] == best } ?? votes.last ?? ""
    }

    static func iou(_ a: NormalizedBox, _ b: NormalizedBox) -> Double {
        let x1 = max(a.x, b.x), y1 = max(a.y, b.y)
        let x2 = min(a.x + a.width, b.x + b.width), y2 = min(a.y + a.height, b.y + b.height)
        let inter = max(0, x2 - x1) * max(0, y2 - y1)
        let union = a.width * a.height + b.width * b.height - inter
        return union > 0 ? inter / union : 0
    }
}
