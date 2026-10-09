import Foundation
import PlateKit

/// Fuses OCR candidates across consecutive frames. Single-frame OCR is noisy;
/// a tracked plate read 5 times with independent lighting/motion micro-jitter
/// converges on truth. Evidence model: plate strings vote per track, and fused
/// confidence is 1 − Π(1 − cᵢ) over agreeing sightings (independent-evidence
/// assumption, standard for multi-frame OCR).
///
/// Track identity is spatial: same-vehicle crops on consecutive frames live
/// near each other (IoU > `trackIoUThreshold`); a track expires after
/// `maxSilence` unseen frames.
public actor MultiFrameFusor {

    public struct Config: Sendable {
        public var trackIoUThreshold: Double      // spatial association
        public var maxSilence: Int                // frames before track expiry
        public var editDistanceMerge: Int         // vote-merging tolerance
        /// Fused candidates below this never surface (multi-frame evidence
        /// should beat a shaky single read, not bury it).
        public var minFusedConfidence: Double

        public static let `default` = Config(trackIoUThreshold: 0.2,
                                             maxSilence: 30,
                                             editDistanceMerge: 1,
                                             minFusedConfidence: 0.25)
        public init(trackIoUThreshold: Double, maxSilence: Int,
                    editDistanceMerge: Int, minFusedConfidence: Double) {
            self.trackIoUThreshold = trackIoUThreshold
            self.maxSilence = maxSilence
            self.editDistanceMerge = editDistanceMerge
            self.minFusedConfidence = minFusedConfidence
        }
    }

    private struct Track {
        var box: NormalizedBox
        /// normalized text → per-sighting confidences
        var votes: [String: [Double]]
        var lastSeenFrame: UInt64
    }

    public struct FusedReading: Sendable {
        public var box: NormalizedBox
        public var text: String
        public var confidence: Double
        public var supportingFrames: UInt64
    }

    private let config: Config
    private var tracks: [Track] = []
    private var frameIndex: UInt64 = 0

    public init(config: Config = .default) { self.config = config }

    /// Ingest one analyzed frame; returns the tracks that currently carry
    /// enough fused evidence to report.
    @discardableResult
    public func ingest(_ frame: DetectionFrame) -> [FusedReading] {
        frameIndex &+= 1

        // Age out expired tracks.
        tracks.removeAll { frameIndex - $0.lastSeenFrame > UInt64(config.maxSilence) }

        // Associate each plate observation with a track (greedy IoU).
        for vehicle in frame.vehicles {
            for plate in vehicle.plates {
                assign(plate: plate)
            }
        }

        return tracks.compactMap(fuse)
    }

    private func assign(plate: PlateObservation) {
        var bestIndex: Int?
        var bestIoU = config.trackIoUThreshold
        for (index, track) in tracks.enumerated() {
            let overlap = iou(track.box, plate.boundingBox)
            if overlap > bestIoU { bestIoU = overlap; bestIndex = index }
        }
        guard let candidate = plate.best else { return }
        let normalized = Plate.normalize(candidate.rawText)
        guard !normalized.isEmpty else { return }

        if let i = bestIndex {
            tracks[i].box = plate.boundingBox
            tracks[i].lastSeenFrame = frameIndex
            // Merge near-miss OCR variants into the dominant reading.
            if let existingKey = tracks[i].votes.keys.first(where: {
                editDistance($0, normalized) <= config.editDistanceMerge
            }) {
                tracks[i].votes[existingKey, default: []].append(candidate.confidence)
            } else {
                tracks[i].votes[normalized, default: []].append(candidate.confidence)
            }
        } else {
            tracks.append(Track(box: plate.boundingBox,
                                votes: [normalized: [candidate.confidence]],
                                lastSeenFrame: frameIndex))
        }
    }

    private func fuse(_ track: Track) -> FusedReading? {
        guard let (text, confidences) = track.votes.max(by: { fusedConfidence($0.value) < fusedConfidence($1.value) })
        else { return nil }
        let confidence = fusedConfidence(confidences)
        guard confidence >= config.minFusedConfidence, confidences.count >= 2 else { return nil }
        return FusedReading(box: track.box, text: text, confidence: confidence,
                            supportingFrames: UInt64(confidences.count))
    }

    private func fusedConfidence(_ confidences: [Double]) -> Double {
        1 - confidences.reduce(1) { $0 * (1 - $1) }
    }

    private func iou(_ a: NormalizedBox, _ b: NormalizedBox) -> Double {
        let x1 = max(a.x, b.x), y1 = max(a.y, b.y)
        let x2 = min(a.x + a.width, b.x + b.width)
        let y2 = min(a.y + a.height, b.y + b.height)
        let inter = max(0, x2 - x1) * max(0, y2 - y1)
        let union = a.width * a.height + b.width * b.height - inter
        return union > 0 ? inter / union : 0
    }

    /// Levenshtein distance (bounded at 8 chars, plate-length).
    private func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + [Int](repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = a[i - 1] == b[j - 1]
                    ? prev[j - 1]
                    : 1 + min(prev[j], cur[j - 1], prev[j - 1])
            }
            prev = cur
        }
        return prev[b.count]
    }
}
