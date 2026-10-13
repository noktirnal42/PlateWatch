#if DEBUG
import CaptureKit
import Foundation
import PlateKit
import VehicleML

/// Debug-only on-device check. Launch with `-PWSelfTest` after copying images
/// into the app container's `Documents/selftest/`; the production analysis
/// path runs on this device and results go to stdout (readable with
/// `devicectl device process launch --console`). Never compiled into Release.
enum SelfTest {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("-PWSelfTest") else { return }
        Task.detached(priority: .userInitiated) {
            await run()
            exit(0)
        }
    }

    private static func run() async {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("selftest")
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["jpg", "jpeg", "png", "webp", "heic"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        print("SELFTEST begin: \(files.count) images, device=\(ProcessInfo.processInfo.hostName)")
        let gate = RedactionGate(config: .standard)
        let executor = AnalysisExecutor(pipeline: PlateAnalysisPipeline()) { AnalysisContext(models: [:]) }
        for url in files {
            guard let buffer = FileFrameSource.pixelBuffer(from: url) else {
                print("SELFTEST \(url.lastPathComponent): DECODE-FAIL"); continue
            }
            let start = Date()
            guard let frame = try? await executor.submit(FramePacketLike(pixelBuffer: buffer), mode: .processAll) else {
                print("SELFTEST \(url.lastPathComponent): ANALYSIS-FAIL"); continue
            }
            // One scoring entry point (PlateKit.FleetScoring) — same as the app and the eval harness.
            var best = 0.0, verdict = RedactionGate.Verdict.discard, markings = FleetMarkings()
            var primary: VehicleObservation?
            for vehicle in frame.vehicles {
                let (c, m) = FleetScoring.vehicleGateScore(gate: gate, vehicle: vehicle)
                if c >= best { best = c; markings = m; verdict = gate.verdict(fleetConfidence: c); primary = vehicle }
            }
            let plates = frame.vehicles.flatMap(\.plates).compactMap(\.best).map(\.text)
            let identity = primary.map { IdentityResolver().resolve(vehicle: $0) }
            let agency = identity?.agency
            print(String(format: "SELFTEST %@ | %@ | conf=%.2f | vehicles=%d | plates=%@ | service=%@ unit=%@ | %.2fs",
                         url.lastPathComponent, "\(verdict)", best, frame.vehicles.count,
                         plates.joined(separator: ","), markings.serviceClassText ?? "-",
                         markings.unitNumber ?? "-", Date().timeIntervalSince(start)))
            if let agency {
                print("SELFTEST   identity | \(agency.name) | key=\(agency.agencyKey) | conf=\(String(format: "%.2f", agency.confidence))"
                      + " | review=\(agency.needsReview) | plateState=\(identity?.plate?.state ?? "-")"
                      + " | alt=\(agency.alternatives.joined(separator: ";"))")
            }
        }
        print("SELFTEST end")
    }
}
#endif
