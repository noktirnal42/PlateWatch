import Foundation
import PlateKit
import VehicleML

/// On-device, display-only type inference. Results never flow back to recording.
actor LiveTypeEnricher {
    typealias Classify = @Sendable (FramePacketLike, NormalizedBox, AnalysisContext) async -> String?
    private let classify: Classify
    private var scope: UUID?
    private var scheduler = LiveTypeScheduler()

    init(classify: @escaping Classify = { frame, box, context in
        await HubVehicleTypeClassifier.classify(frame, box: box, context: context)
    }) { self.classify = classify }

    func enrich(_ frame: DetectionFrame, input: FramePacketLike, context: AnalysisContext,
                scope: UUID, now: TimeInterval) async -> DetectionFrame {
        if self.scope != scope { self.scope = scope; scheduler = LiveTypeScheduler() }
        let plan = scheduler.prepare(frame.vehicles, imageSize: frame.imageSize, now: now)
        for item in plan.requests {
            guard !Task.isCancelled, self.scope == scope else { return frame }
            let result = await classify(input, frame.vehicles[item.index].boundingBox, context)
            guard !Task.isCancelled, self.scope == scope else { return frame }
            scheduler.record(result, track: item.track, now: now)
        }
        var display = frame
        for item in plan.assignments {
            if let body = scheduler.body(for: item.track, now: now) {
                var attributes = display.vehicles[item.index].attributes ?? VehicleAttributes()
                attributes.bodyType = body
                display.vehicles[item.index].attributes = attributes
            }
        }
        return display
    }
}
