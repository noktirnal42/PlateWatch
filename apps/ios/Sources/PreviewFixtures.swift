import Foundation
import PlateKit
import PlateSync
import SwiftData
import SwiftUI

/// Explicit, DEBUG-only screenshot fixtures. In-memory models, no camera,
/// location, subscriptions or outbox delivery. Never used in release builds.
enum PreviewFixtures {
    static var isEnabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-PWPreviewData")
        #else
        false
        #endif
    }

    static var initialTab: Int {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-PWTab"), args.indices.contains(i + 1), let tab = Int(args[i + 1]), (0...4).contains(tab) { return tab }
        #endif
        return 0
    }

    @MainActor static func populate(_ container: ModelContainer) {
        #if DEBUG
        guard isEnabled else { return }
        let context = container.mainContext
        let date = Date(timeIntervalSince1970: 1_792_008_000)
        for (index, service) in ["Public Works", "Transit"].enumerated() {
            let dto = SightingSubmissionDTO(capturedAt: date.addingTimeInterval(Double(index) * -300),
                                           geohash6: "9q8yyk", deviceIDHash: "preview-only-never-uploaded",
                                           fleetConfidence: 0.83, plate: .init(text: "DEMO\(index + 1)"),
                                           vehicle: .init(vehicleClass: "serviceTruck", classConfidence: 0.9),
                                           markings: .init(unitNumber: "\(104 + index)", serviceClassText: service))
            if let data = try? JSONEncoder.withISODates.encode(dto) {
                context.insert(PendingSubmission(idempotencyKey: "preview-\(index)", payloadJSON: data,
                                                 createdAt: dto.capturedAt, retryCount: index == 0 ? 8 : 0))
            }
        }
        context.insert(WatchlistItem(plateText: "DEMO1", notifyEnabled: true))
        context.insert(WatchlistItem(plateText: "DEMO2", notifyEnabled: false))
        try? context.save()
        #endif
    }
}

/// Audit appearance overrides apply only inside the isolated debug preview.
struct PreviewAppearance: ViewModifier {
    func body(content: Content) -> some View {
        if PreviewFixtures.isEnabled {
            if ProcessInfo.processInfo.arguments.contains("-PWPreviewLargeText") {
                content.dynamicTypeSize(.accessibility3)
                    .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("-PWPreviewDark") ? .dark : nil)
            } else {
                content.preferredColorScheme(ProcessInfo.processInfo.arguments.contains("-PWPreviewDark") ? .dark : nil)
            }
        } else {
            content
        }
    }
}

struct PreviewBanner: View {
    var body: some View {
        if PreviewFixtures.isEnabled {
            Text("DEMO DATA · LOCAL PREVIEW").font(.caption2.weight(.bold)).tracking(1)
                .frame(maxWidth: .infinity).padding(6)
                .foregroundStyle(.black).background(PWStyle.fleet)
        }
    }
}
