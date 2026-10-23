import CoreVideo
import CoreImage
import CoreML
import PlateKit
import VehicleML
import XCTest

final class LiveTypeTests: XCTestCase {
    private func vehicles(_ count: Int) -> [VehicleObservation] {
        (0..<count).map { i in
            VehicleObservation(boundingBox: .init(x: Double(i % 5) * 0.19, y: Double(i / 5) * 0.3,
                                                 width: 0.12, height: 0.2),
                               attributes: VehicleAttributes(bodyType: "car"))
        }
    }
    private let size = CGSize(width: 1000, height: 1000)

    func testCrowdedFrameVisitsEveryTrackBeforeRepeatingEarlyTracks() {
        var scheduler = LiveTypeScheduler()
        let cars = vehicles(10)
        let a = scheduler.prepare(cars, imageSize: size, now: 0)
        let b = scheduler.prepare(cars, imageSize: size, now: 1)
        let c = scheduler.prepare(cars, imageSize: size, now: 2)
        XCTAssertEqual(a.requests.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(b.requests.map(\.index), [4, 5, 6, 7])
        XCTAssertEqual(Array(c.requests.prefix(2)).map(\.index), [8, 9])
        XCTAssertEqual(Set((a.requests + b.requests + c.requests).map(\.index)), Set(0..<10))
        XCTAssertLessThanOrEqual(c.requests.count, 4)
    }

    func testCooldownCacheExpiryAndNoTransferToNonOverlappingVehicle() throws {
        var scheduler = LiveTypeScheduler()
        let car = vehicles(1)
        let first = scheduler.prepare(car, imageSize: size, now: 0)
        let id = try XCTUnwrap(first.requests.first?.track)
        scheduler.record("suv", track: id, now: 0)
        XCTAssertTrue(scheduler.prepare(car, imageSize: size, now: 1).requests.isEmpty)
        XCTAssertEqual(scheduler.body(for: id, now: 1), "suv")
        XCTAssertNil(scheduler.body(for: id, now: 3.1))
        var moved = car
        moved[0].boundingBox.x = 0.8
        let next = scheduler.prepare(moved, imageSize: size, now: 3.1)
        XCTAssertNotEqual(next.assignments.first?.track, id)
        XCTAssertNil(scheduler.body(for: try XCTUnwrap(next.assignments.first?.track), now: 3.1))
    }

    func testNewArrivalsCannotPermanentlyDisplaceOverdueTracks() {
        var scheduler = LiveTypeScheduler()
        var cars = vehicles(4)
        _ = scheduler.prepare(cars, imageSize: size, now: 0)
        cars = vehicles(8)
        XCTAssertEqual(scheduler.prepare(cars, imageSize: size, now: 1).requests.map(\.index), [4, 5, 6, 7])
        cars = vehicles(12)
        XCTAssertEqual(scheduler.prepare(cars, imageSize: size, now: 2.1).requests.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(scheduler.prepare(cars, imageSize: size, now: 3.1).requests.map(\.index), [8, 9, 10, 11])
    }

    func testEligibleCropFilteringAndMetadataBounds() {
        var scheduler = LiveTypeScheduler()
        var cars = vehicles(4)
        cars[0].attributes?.bodyType = "bus"
        cars[1].boundingBox.width = 0.01
        cars[2].boundingBox.x = 2
        XCTAssertEqual(scheduler.prepare(cars, imageSize: size, now: 0).requests.map(\.index), [3])
        _ = scheduler.prepare(vehicles(200), imageSize: size, now: 1)
        XCTAssertLessThanOrEqual(scheduler.count, LiveTypeScheduler.capacity)
        _ = scheduler.prepare([], imageSize: size, now: 7)
        XCTAssertEqual(scheduler.count, 0)
    }

    func testSyntheticHundredTickBudgetIsBoundedAndCoversAllTenTracks() {
        var scheduler = LiveTypeScheduler()
        let cars = vehicles(10)
        var count = 0, visited: Set<Int> = []
        for tick in 0..<100 {
            let plan = scheduler.prepare(cars, imageSize: size, now: Double(tick) / 10)
            XCTAssertLessThanOrEqual(plan.requests.count, 4)
            count += plan.requests.count
            visited.formUnion(plan.requests.map(\.index))
        }
        XCTAssertEqual(visited, Set(0..<10))
        XCTAssertLessThanOrEqual(count, 60, "Cooldown must prevent reclassifying every visible crop on every tick")
    }

    func testEstimatedTypeNeverBorrowsDetectorConfidence() {
        var car = vehicles(1)[0]
        car.attributes?.bodyType = "suv"
        car.classConfidence = 0.99
        XCTAssertEqual(VehicleOverlayLabel.text(for: car, fleetConfidence: 0, bodyTypeEstimated: true), "SUV (estimate)")
        car.vehicleClass = .patrol
        XCTAssertEqual(VehicleOverlayLabel.text(for: car, fleetConfidence: 0.8, bodyTypeEstimated: true),
                       "SUV (estimate) · Patrol · fleet 80%")
    }

    func testLabelSmoothingCannotExtendExpiredEstimate() {
        var tracker = LiveBoxTracker()
        let box = NormalizedBox(x: 0.2, y: 0.2, width: 0.2, height: 0.2)
        for _ in 0..<8 {
            _ = tracker.update([.init(rect: box, label: "SUV (estimate)", isFleet: false, uncertain: false)])
        }
        let ended = tracker.update([.init(rect: box, label: "Car · class 99%", isFleet: false, uncertain: false)])
        XCTAssertEqual(ended.first?.label, "Car · class 99%")
        let renewed = tracker.update([.init(rect: box, label: "SUV (estimate)", isFleet: false, uncertain: false)])
        XCTAssertEqual(renewed.first?.label, "SUV (estimate)")
    }

    func testLogitsAreNormalizedBeforeConfidenceAndUnknownLabelsAbstain() {
        XCTAssertEqual(HubVehicleTypeClassifier.bodyType(logits: ["car": 2, "truck": 0]), "car")
        XCTAssertNil(HubVehicleTypeClassifier.bodyType(logits: ["car": 0, "truck": 0, "bus": 0]))
        XCTAssertNil(HubVehicleTypeClassifier.bodyType(logits: ["bicycle": 10, "car": 0]))
        XCTAssertNil(HubVehicleTypeClassifier.bodyType(logits: ["car": .nan]))
    }

    func testReleasedAppearanceClassesNeverImplyFleet() {
        XCTAssertEqual(HubVehicleTypeClassifier.legacyBodyType(for: "fire engine"), "truck")
        XCTAssertEqual(HubVehicleTypeClassifier.legacyBodyType(for: "taxi"), "car")
        XCTAssertEqual(HubVehicleTypeClassifier.legacyBodyType(for: "jeep"), "suv")
        XCTAssertNil(HubVehicleTypeClassifier.legacyBodyType(for: "person"))
    }

    func testTensorRGBNormalizationAndTopLeftOrientation() throws {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA, nil, &pixels), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 2, width: 4, height: 2))
        CIContext().render(red.composited(over: blue), to: buffer)
        let tensor = try XCTUnwrap(HubVehicleTypeClassifier.tensor(.init(pixelBuffer: buffer),
                                                                 box: .init(x: 0, y: 0, width: 1, height: 1)))
        XCTAssertEqual(tensor.shape.map(\.intValue), [1, 3, 224, 224])
        XCTAssertEqual(tensor[[0, 0, 0, 0] as [NSNumber]].floatValue, 1, accuracy: 0.01)
        XCTAssertEqual(tensor[[0, 2, 0, 0] as [NSNumber]].floatValue, -1, accuracy: 0.01)
        XCTAssertEqual(tensor[[0, 0, 223, 0] as [NSNumber]].floatValue, -1, accuracy: 0.01)
        XCTAssertEqual(tensor[[0, 2, 223, 0] as [NSNumber]].floatValue, 1, accuracy: 0.01)
    }

    private func input() throws -> FramePacketLike {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 1000, 1000, kCVPixelFormatType_32BGRA,
                                           nil, &pixels), kCVReturnSuccess)
        return .init(pixelBuffer: try XCTUnwrap(pixels))
    }

    func testCachedDisplayTypeDoesNotChangeOriginalFleetEvidence() async throws {
        let calls = CallCounter()
        let enricher = LiveTypeEnricher { _, _, _ in await calls.record(); return "suv" }
        var cars = vehicles(1)
        cars[0].vehicleClass = .patrol
        cars[0].classConfidence = 0.91
        let frame = DetectionFrame(timestamp: Date(), imageSize: size, vehicles: cars)
        let input = try input(), scope = UUID()
        let result = await enricher.enrich(frame, input: input, context: .init(), scope: scope, now: 0)
        let cached = await enricher.enrich(frame, input: input, context: .init(), scope: scope, now: 1)
        XCTAssertEqual(result.vehicles[0].attributes?.bodyType, "suv")
        XCTAssertEqual(cached.vehicles[0].attributes?.bodyType, "suv")
        XCTAssertEqual(frame.vehicles[0].attributes?.bodyType, "car")
        XCTAssertEqual(result.vehicles[0].vehicleClass, frame.vehicles[0].vehicleClass)
        XCTAssertEqual(result.vehicles[0].classConfidence, 0.91)
        XCTAssertEqual(result.vehicles[0].id, frame.vehicles[0].id)
        let count = await calls.count
        XCTAssertEqual(count, 1)
    }

    func testLateResultFromOldSessionCannotEnterNewCache() async throws {
        let gate = ClassificationGate()
        let enricher = LiveTypeEnricher { _, _, _ in await gate.classify() }
        let frame = DetectionFrame(timestamp: Date(), imageSize: size, vehicles: vehicles(1))
        let input = try input(), old = UUID(), new = UUID()
        let pending = Task { await enricher.enrich(frame, input: input, context: .init(), scope: old, now: 0) }
        await gate.waitUntilStarted()
        let current = await enricher.enrich(frame, input: input, context: .init(), scope: new, now: 1)
        await gate.release()
        let stale = await pending.value
        let cached = await enricher.enrich(frame, input: input, context: .init(), scope: new, now: 2)
        XCTAssertEqual(current.vehicles[0].attributes?.bodyType, "van")
        XCTAssertEqual(stale.vehicles[0].attributes?.bodyType, "car")
        XCTAssertEqual(cached.vehicles[0].attributes?.bodyType, "van")
    }
    /// Local licensed photo + cached model only; no download or media export.
    func testInstalledTypeModelInferenceAndCooldown() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let modelPath = env["PLATEWATCH_VEHICLE_TYPE_MODEL"], let imagePath = env["PLATEWATCH_TYPE_IMAGE"] else {
            throw XCTSkip("Set local vehicle-type model and licensed image paths for native inference")
        }
        let url = URL(fileURLWithPath: modelPath)
        let compiled = url.pathExtension == "mlmodelc" ? url : try await MLModel.compileModel(at: url)
        let model = try MLModel(contentsOf: compiled)
        let source = try XCTUnwrap(CIImage(contentsOf: URL(fileURLWithPath: imagePath)))
        let scale = min(1, 1000 / max(source.extent.width, source.extent.height))
        let image = source.transformed(by: .init(scaleX: scale, y: scale))
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, Int(image.extent.width), Int(image.extent.height),
                                         kCVPixelFormatType_32BGRA, nil, &pixels), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        CIContext().render(image, to: buffer)
        let context = AnalysisContext(models: ["vehicle-type-classification": model])
        let calls = CallCounter()
        let enricher = LiveTypeEnricher { input, box, context in
            let body = await HubVehicleTypeClassifier.classify(input, box: box, context: context)
            await calls.record(body)
            return body
        }
        let frame = DetectionFrame(timestamp: Date(), imageSize: image.extent.size,
            vehicles: [VehicleObservation(boundingBox: .init(x: 0, y: 0, width: 1, height: 1))])
        let scope = UUID(), input = FramePacketLike(pixelBuffer: buffer)
        let first = await enricher.enrich(frame, input: input, context: context, scope: scope, now: 0)
        let accepted = await calls.lastBody
        let tensor = try XCTUnwrap(HubVehicleTypeClassifier.tensor(input, box: .init(x: 0, y: 0, width: 1, height: 1)))
        let logits = try HubVehicleTypeClassifier.logits(model, tensor: tensor)
        XCTAssertEqual(logits.count, 10, "The released tensor classifier must actually execute")
        XCTAssertTrue(logits.values.allSatisfy(\.isFinite))
        let expected = HubVehicleTypeClassifier.bodyType(logits: logits)
        XCTAssertEqual(accepted, expected, "Weak native scores must abstain without lowering the threshold")
        let cached = await enricher.enrich(frame, input: input, context: context, scope: scope, now: 1)
        XCTAssertEqual(first.vehicles[0].attributes?.bodyType, accepted)
        XCTAssertEqual(cached.vehicles[0].attributes?.bodyType, accepted)
        let count = await calls.count
        XCTAssertEqual(count, 1)
    }

    func testCancelledInferenceCannotPopulateCache() async throws {
        let gate = ClassificationGate()
        let enricher = LiveTypeEnricher { _, _, _ in await gate.classify() }
        let frame = DetectionFrame(timestamp: Date(), imageSize: size, vehicles: vehicles(1))
        let input = try input(), scope = UUID()
        let pending = Task { await enricher.enrich(frame, input: input, context: .init(), scope: scope, now: 0) }
        await gate.waitUntilStarted()
        pending.cancel()
        await gate.release()
        let result = await pending.value
        let cached = await enricher.enrich(frame, input: input, context: .init(), scope: scope, now: 1)
        XCTAssertEqual(result.vehicles[0].attributes?.bodyType, "car")
        XCTAssertEqual(cached.vehicles[0].attributes?.bodyType, "car")
    }

}

private actor CallCounter {
    var count = 0
    var lastBody: String?
    func record(_ body: String? = nil) { count += 1; lastBody = body }
}

private actor ClassificationGate {
    private var started = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var pending: CheckedContinuation<String?, Never>?
    func classify() async -> String? {
        if started { return "van" }
        started = true
        waiting?.resume(); waiting = nil
        return await withCheckedContinuation { pending = $0 }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func release() { pending?.resume(returning: "suv"); pending = nil }
}
