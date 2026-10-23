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
        /// Smoothed motion of the box origin in frame fractions per second, used only to glide the box between analysed frames.
        var velocity: (x: Double, y: Double)
    }

    static let matchIoU = 0.3
    /// Weight of the newest detection in a matched box's position (1 = no smoothing).
    static let smoothing = 0.65
    static let maxMisses = 3
    static let voteWindow = 7

    private struct Track {
        var id = UUID()
        var rect: NormalizedBox
        var shown: (label: String, isFleet: Bool, uncertain: Bool)?
        var votes: [String] = []
        var hits = 1
        var misses = 0
        var seenAt: TimeInterval = 0
        /// A full analysis frame has classified this vehicle; until then the box is drawn dashed.
        var classified = false
        var velocity: (x: Double, y: Double) = (0, 0)
    }
    private var tracks: [Track] = []

    mutating func reset() { tracks = [] }

    /// `authoritative` is true for full-analysis frames (their labels and fleet verdicts are shown and recorded as the track's
    /// state). A fast, detector-only frame (`false`) moves matched boxes but keeps what the last full frame said about them;
    /// only boxes it newly discovers show its generic label until the next full frame.
    mutating func update(authoritative: Bool = true, now: TimeInterval = ProcessInfo.processInfo.systemUptime, _ detections: [Detection]) -> [Tracked] {
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
                let dt = now - tracks[t].seenAt
                if dt > 0.02, dt < 1.5 {
                    let vx = (detection.rect.x - tracks[t].rect.x) / dt, vy = (detection.rect.y - tracks[t].rect.y) / dt
                    tracks[t].velocity = (0.5 * tracks[t].velocity.x + 0.5 * vx, 0.5 * tracks[t].velocity.y + 0.5 * vy)
                }
                // Detector boxes jitter a few pixels frame to frame; blend with the previous position so the box glides.
                let prev = tracks[t].rect, a = Self.smoothing
                tracks[t].rect = NormalizedBox(x: prev.x + (detection.rect.x - prev.x) * a, y: prev.y + (detection.rect.y - prev.y) * a,
                                               width: prev.width + (detection.rect.width - prev.width) * a,
                                               height: prev.height + (detection.rect.height - prev.height) * a)
                tracks[t].seenAt = now
                tracks[t].misses = 0
                tracks[t].hits += 1
            } else {
                tracks.append(Track(rect: detection.rect, seenAt: now)); t = tracks.count - 1
            }
            if !authoritative, trackFor[d] != nil, let shown = tracks[t].shown {
                out.append(Tracked(id: tracks[t].id, rect: tracks[t].rect, label: shown.label, isFleet: shown.isFleet,
                                   uncertain: shown.uncertain, hits: tracks[t].hits, velocity: tracks[t].velocity))
                continue
            }
            let parts = detection.label.components(separatedBy: " · ")
            let currentBase = parts.first ?? detection.label
            if authoritative, let previous = tracks[t].shown?.label.components(separatedBy: " · ").first,
               previous.hasSuffix(" (estimate)") != currentBase.hasSuffix(" (estimate)") {
                // Smoothing must not extend an expired model estimate or attach
                // the detector's confidence to a previous estimated body type.
                tracks[t].votes = []
            }
            tracks[t].votes.append(currentBase)
            if tracks[t].votes.count > Self.voteWindow { tracks[t].votes.removeFirst(tracks[t].votes.count - Self.voteWindow) }
            let base = Self.winner(tracks[t].votes)
            let label = ([base] + parts.dropFirst()).joined(separator: " · ")
            if authoritative { tracks[t].classified = true }
            let uncertain = !tracks[t].classified || (detection.uncertain && base.hasPrefix("Vehicle"))
            if authoritative || tracks[t].shown == nil { tracks[t].shown = (label, detection.isFleet, uncertain) }
            out.append(Tracked(id: tracks[t].id, rect: tracks[t].rect, label: label, isFleet: detection.isFleet,
                               uncertain: uncertain, hits: tracks[t].hits, velocity: tracks[t].velocity))
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
