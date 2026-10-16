import XCTest
import AVFoundation
import CoreVideo
import CoreMedia
@testable import CaptureKit

private func makeTestPixelBuffer() -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &pb)
    return pb!
}

final class CaptureConfigurationTests: XCTestCase {
    func testPresetsHaveSanePhysics() {
        XCTAssertEqual(CaptureConfiguration.dashcam.minimumShutterSeconds, 0.001, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(CaptureConfiguration.handheld.analyzeEveryNthFrame, 2)
        XCTAssertTrue(CaptureConfiguration.handheld.preferTelephoto)
    }

    func testNewConfigurationFields() {
        let config = CaptureConfiguration.handheld
        XCTAssertEqual(config.maximumISO, 800)
        XCTAssertTrue(config.enableAdaptiveExposure)
        XCTAssertEqual(config.eventClipPreRollSeconds, 2.0)
        XCTAssertEqual(config.eventClipPostRollSeconds, 1.0)

        let dashcam = CaptureConfiguration.dashcam
        XCTAssertEqual(dashcam.maximumISO, 1600)
        XCTAssertEqual(dashcam.eventClipPreRollSeconds, 3.0)
        XCTAssertEqual(dashcam.eventClipPostRollSeconds, 2.0)
    }

    func testCustomConfiguration() {
        let custom = CaptureConfiguration(
            analyzeEveryNthFrame: 1,
            preset: .hd4K3840x2160,
            preferTelephoto: false,
            minimumShutterSeconds: 1.0 / 250.0,
            maximumISO: 400,
            enableAdaptiveExposure: false,
            eventClipPreRollSeconds: 1.0,
            eventClipPostRollSeconds: 0.5
        )
        XCTAssertEqual(custom.analyzeEveryNthFrame, 1)
        XCTAssertEqual(custom.minimumShutterSeconds, 0.004, accuracy: 0.0001)
        XCTAssertEqual(custom.maximumISO, 400)
        XCTAssertFalse(custom.enableAdaptiveExposure)
    }
}

final class FrameRollingBufferTests: XCTestCase {
    func testAppendAndCount() {
        let buffer = FrameRollingBuffer(maxFrames: 5)
        XCTAssertEqual(buffer.count, 0)

        let frame = FramePacket(
            pixelBuffer: makeTestPixelBuffer(),
            timestamp: Date(),
            sequenceNumber: 1
        )
        buffer.append(frame)
        XCTAssertEqual(buffer.count, 1)
    }

    func testMaxFramesEnforced() {
        let buffer = FrameRollingBuffer(maxFrames: 3)
        for i in 1...5 {
            buffer.append(FramePacket(
                pixelBuffer: makeTestPixelBuffer(),
                timestamp: Date(),
                sequenceNumber: UInt64(i)
            ))
        }
        XCTAssertEqual(buffer.count, 3)
    }

    func testExtractClip() {
        let buffer = FrameRollingBuffer(maxFrames: 10)
        for i in 1...10 {
            let frame = FramePacket(
                pixelBuffer: makeTestPixelBuffer(),
                timestamp: Date().addingTimeInterval(TimeInterval(i)),
                sequenceNumber: UInt64(i)
            )
            buffer.append(frame)
        }

        // Indices are absolute frame numbers: [2, 7] inclusive = seq 2…7.
        let clip = buffer.extractClip(from: 2, to: 7)
        XCTAssertEqual(clip.count, 6)
        XCTAssertEqual(clip.first?.sequenceNumber, 2)
        XCTAssertEqual(clip.last?.sequenceNumber, 7)
    }

    func testExtractClipBoundsClamped() {
        let buffer = FrameRollingBuffer(maxFrames: 5)
        for i in 1...5 {
            buffer.append(FramePacket(
                pixelBuffer: makeTestPixelBuffer(),
                timestamp: Date(),
                sequenceNumber: UInt64(i)
            ))
        }

        // Out of bounds should be clamped
        let clip = buffer.extractClip(from: -2, to: 10)
        XCTAssertEqual(clip.count, 5)
    }

    /// Regression: extractEventClip passes ABSOLUTE frame counters, so the
    /// buffer must survive windows that start past the retained prefix.
    /// Position-based slicing here formed an invalid Array range and
    /// crashed the capture session on the first post-wrap fleet event.
    func testExtractClipAfterEviction() {
        let buffer = FrameRollingBuffer(maxFrames: 5)
        for i in 1...20 {
            buffer.append(FramePacket(
                pixelBuffer: makeTestPixelBuffer(),
                timestamp: Date(),
                sequenceNumber: UInt64(i)
            ))
        }
        XCTAssertEqual(buffer.count, 5) // seq 16…20 retained

        let clip = buffer.extractClip(from: 17, to: 22)
        XCTAssertEqual(clip.first?.sequenceNumber, 17)
        XCTAssertEqual(clip.last?.sequenceNumber, 20)

        // Fully-evicted window: empty, not a crash.
        XCTAssertTrue(buffer.extractClip(from: 1, to: 10).isEmpty)
        // Inverted range: empty, not a crash.
        XCTAssertTrue(buffer.extractClip(from: 10, to: 2).isEmpty)
    }

    func testFramesInLast() {
        let buffer = FrameRollingBuffer(maxFrames: 10)
        let now = Date()
        for i in 0..<5 {
            buffer.append(FramePacket(
                pixelBuffer: makeTestPixelBuffer(),
                timestamp: now.addingTimeInterval(-Double(i) * 0.5),
                sequenceNumber: UInt64(i)
            ))
        }

        // Frames at 0.0, 0.5, 1.0, 1.5, 2.0 seconds ago
        // Within 1.0 seconds: 0.0 and 0.5 = 2 frames
        let recent = buffer.framesInLast(1.0)
        XCTAssertEqual(recent.count, 2)
    }
}

final class EventClipMetadataTests: XCTestCase {
    func testMetadataDescribesPartialBufferWithoutTouchingPixels() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let frames = (0..<3).map { index in
            FramePacket(pixelBuffer: makeTestPixelBuffer(),
                        timestamp: start.addingTimeInterval(Double(index) * 0.25),
                        sequenceNumber: UInt64(index + 10))
        }
        let clip = EventClip(frames: frames, triggerFrameIndex: 1,
                             triggerTimestamp: frames[1].timestamp)
        XCTAssertEqual(clip.frameCount, 3)
        XCTAssertEqual(clip.duration, 0.5, accuracy: 0.001)
        XCTAssertEqual(clip.startTimestamp, start)
        XCTAssertEqual(clip.endTimestamp, start.addingTimeInterval(0.5))
    }

    func testExporterWritesBoundedLocalMovie() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let frames = (0..<3).map { index in
            FramePacket(pixelBuffer: makeTestPixelBuffer(),
                        timestamp: start.addingTimeInterval(Double(index) * 0.1),
                        sequenceNumber: UInt64(index))
        }
        let clip = EventClip(frames: frames, triggerFrameIndex: 1, triggerTimestamp: frames[1].timestamp)
        let url = FileManager.default.temporaryDirectory.appending(path: "platewatch-export-test-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }

        try EventClipExporter.export(clip, to: url)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertGreaterThan((attrs[.size] as? NSNumber)?.intValue ?? 0, 0)
    }
}

final class AdaptiveExposureControllerTests: XCTestCase {
    func testShutterBelowMinimumIncreasesISO() {
        let controller = AdaptiveExposureController(minShutter: 1.0/1000.0, maxISO: 800)

        // Shutter at 1/250s (0.004s) which is SLOWER (longer) than minimum 1/1000s (0.001s)
        // Should suggest increasing ISO to maintain minimum shutter
        _ = controller.update(measuredShutter: 1.0/250.0, measuredISO: 200)
        // Frame count needs to reach 10 for adjustment (10th call triggers at frameCount=10)
        var finalResult: (CMTime, Float)?
        for i in 0..<10 {
            finalResult = controller.update(measuredShutter: 1.0/250.0, measuredISO: 200)
            if i == 8 { break } // capture the 10th call (frameCount=10)
        }
        XCTAssertNotNil(finalResult)
        if let (shutter, iso) = finalResult {
            XCTAssertEqual(shutter.seconds, 1.0/1000.0, accuracy: 0.00001)
            XCTAssertGreaterThan(iso, 200)
        }
    }

    func testISOAtCeilingStopsAdjustment() {
        let controller = AdaptiveExposureController(minShutter: 1.0/500.0, maxISO: 800)

        // ISO already at max, shutter slow - should not adjust
        for _ in 0..<9 {
            _ = controller.update(measuredShutter: 1.0/250.0, measuredISO: 780)
        }
        let result = controller.update(measuredShutter: 1.0/250.0, measuredISO: 780)
        XCTAssertNil(result)
    }

    func testExcessLightRelaxesShutter() {
        let controller = AdaptiveExposureController(minShutter: 1.0/500.0, maxISO: 800)

        // Very fast shutter (1/2000s) and low ISO (100) - excess light
        for _ in 0..<9 {
            _ = controller.update(measuredShutter: 1.0/2000.0, measuredISO: 100)
        }
        let result = controller.update(measuredShutter: 1.0/2000.0, measuredISO: 100)
        XCTAssertNotNil(result)
        if let (shutter, iso) = result {
            XCTAssertEqual(iso, 100)
            XCTAssertGreaterThan(shutter.seconds, 1.0/2000.0)
            XCTAssertLessThanOrEqual(shutter.seconds, 1.0/500.0)
        }
    }
}
