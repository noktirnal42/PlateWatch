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
            .filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
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
            var best = 0.0, verdict = RedactionGate.Verdict.discard, markings = FleetMarkings()
            for vehicle in frame.vehicles {
                let m = SceneTextHeuristics.parse(vehicle.sceneText)
                let c = gate.fleetConfidence(
                    vehicleClassifierFleet: vehicle.vehicleClass.isFleet ? vehicle.classConfidence : 0,
                    markings: m, knownUnitMatch: false,
                    exemptPlateDesign: vehicle.plates.contains { $0.best?.exemptDesignHint == true },
                officialPlate: vehicle.plates.contains { $0.best?.isOfficialPlate == true })
                if c >= best { best = c; markings = m; verdict = gate.verdict(fleetConfidence: c) }
            }
            let plates = frame.vehicles.flatMap(\.plates).compactMap(\.best).map(\.text)
            print(String(format: "SELFTEST %@ | %@ | conf=%.2f | vehicles=%d | plates=%@ | service=%@ unit=%@ | %.2fs",
                         url.lastPathComponent, "\(verdict)", best, frame.vehicles.count,
                         plates.joined(separator: ","), markings.serviceClassText ?? "-",
                         markings.unitNumber ?? "-", Date().timeIntervalSince(start)))
        }
        print("SELFTEST end")
    }
}
#endif
