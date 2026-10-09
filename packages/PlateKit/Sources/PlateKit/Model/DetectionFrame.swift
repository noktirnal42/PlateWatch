import Foundation
import CoreGraphics

/// Normalized (0…1) rectangle in image coordinates, origin top-left.
public struct NormalizedBox: Sendable, Codable, Hashable {
    public var x, y, width, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    /// Vision boxes are bottom-left origin; convert up front so all
    /// downstream code shares one convention.
    public init(visionRect: CGRect) {
        self.init(x: visionRect.minX, y: 1 - visionRect.maxY,
                  width: visionRect.width, height: visionRect.height)
    }
}

/// Output of one pipeline run over one frame — the currency between
/// CaptureKit, VehicleML and PlateKit redaction.
public struct DetectionFrame: Sendable {
    public var timestamp: Date
    public var imageSize: CGSize
    public var vehicles: [VehicleObservation]

    public init(timestamp: Date, imageSize: CGSize, vehicles: [VehicleObservation] = []) {
        self.timestamp = timestamp
        self.imageSize = imageSize
        self.vehicles = vehicles
    }
}

public struct VehicleObservation: Sendable, Identifiable {
    public let id: UUID
    public var boundingBox: NormalizedBox
    public var vehicleClass: VehicleClass
    public var classConfidence: Double
    public var plates: [PlateObservation]
    /// All scene text read on/near the vehicle (doors, roof, hood) —
    /// input for the fleet-markings parser.
    public var sceneText: [SceneTextObservation]
    /// Perceptual feature print for re-identification (hex).
    public var featurePrintAnchorLookahead: String?
    /// Classifier-derived attributes, when available.
    public var attributes: VehicleAttributes?

    public init(id: UUID = UUID(), boundingBox: NormalizedBox,
                vehicleClass: VehicleClass = .unknown, classConfidence: Double = 0,
                plates: [PlateObservation] = [], sceneText: [SceneTextObservation] = [],
                featurePrintAnchorLookahead: String? = nil, attributes: VehicleAttributes? = nil) {
        self.id = id
        self.boundingBox = boundingBox
        self.vehicleClass = vehicleClass
        self.classConfidence = classConfidence
        self.plates = plates
        self.sceneText = sceneText
        self.featurePrintAnchorLookahead = featurePrintAnchorLookahead
        self.attributes = attributes
    }
}

public struct PlateObservation: Sendable, Identifiable {
    public let id: UUID
    public var boundingBox: NormalizedBox
    /// Top-N OCR candidates, best first (OpenALPR convention).
    public var candidates: [Plate]
    public var cropHashSHA256: String?

    public var best: Plate? { candidates.first }

    public init(id: UUID = UUID(), boundingBox: NormalizedBox,
                candidates: [Plate], cropHashSHA256: String? = nil) {
        self.id = id
        self.boundingBox = boundingBox
        self.candidates = candidates
        self.cropHashSHA256 = cropHashSHA256
    }
}

public struct SceneTextObservation: Sendable, Identifiable {
    public let id: UUID
    public var text: String
    public var boundingBox: NormalizedBox
    public var confidence: Double

    public init(id: UUID = UUID(), text: String, boundingBox: NormalizedBox, confidence: Double) {
        self.id = id
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
    }
}

public struct VehicleAttributes: Sendable, Codable, Hashable {
    public var make: String?
    public var model: String?
    public var color: String?
    public var bodyType: String?
    /// Light bar / push bar / spotlight / municipal decal indicators.
    public var hasLightBar: Bool?
    public var hasPushBar: Bool?
    public var hasFleetDecals: Bool?

    public init(make: String? = nil, model: String? = nil, color: String? = nil,
                bodyType: String? = nil, hasLightBar: Bool? = nil,
                hasPushBar: Bool? = nil, hasFleetDecals: Bool? = nil) {
        self.make = make; self.model = model; self.color = color
        self.bodyType = bodyType
        self.hasLightBar = hasLightBar; self.hasPushBar = hasPushBar
        self.hasFleetDecals = hasFleetDecals
    }
}
