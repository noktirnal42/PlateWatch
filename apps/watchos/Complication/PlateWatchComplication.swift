import SwiftUI
import WidgetKit

struct PlateWatchComplicationEntry: TimelineEntry {
    let date: Date
    let fleetHits: Int
    let activeUsers: Int?
}

struct PlateWatchComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> PlateWatchComplicationEntry {
        PlateWatchComplicationEntry(date: .now, fleetHits: 3, activeUsers: 2)
    }

    func getSnapshot(in context: Context,
                     completion: @escaping (PlateWatchComplicationEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context,
                     completion: @escaping (Timeline<PlateWatchComplicationEntry>) -> Void) {
        let entry = currentEntry()
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(900))))
    }

    private func currentEntry() -> PlateWatchComplicationEntry {
        PlateWatchComplicationEntry(date: .now,
                                    fleetHits: WatchComplicationStore.fleetHitCount(),
                                    activeUsers: WatchComplicationStore.activeUserCount())
    }
}

struct PlateWatchComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PlateWatchComplicationEntry

    var body: some View {
        switch family {
        case .accessoryInline:
            Text("Fleet \(entry.fleetHits) · Users \(entry.activeUsers.map(String.init) ?? "—")")
        case .accessoryCircular:
            VStack(spacing: 1) {
                Label("\(entry.fleetHits)", systemImage: "car.fill")
                    .labelStyle(.titleAndIcon)
                Label(entry.activeUsers.map(String.init) ?? "—", systemImage: "person.2.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2)
            }
        default:
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Label("\(entry.fleetHits)", systemImage: "car.fill")
                    Text("Fleet hits").font(.caption2)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Label(entry.activeUsers.map(String.init) ?? "—", systemImage: "person.2.fill")
                    Text("Active users").font(.caption2)
                }
            }
        }
    }
}

struct PlateWatchComplication: Widget {
    let kind = WatchComplicationStore.kind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PlateWatchComplicationProvider()) { entry in
            PlateWatchComplicationView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("PlateWatch")
        .description("Fleet hits and active PlateWatch users")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct PlateWatchComplicationBundle: WidgetBundle {
    var body: some Widget {
        PlateWatchComplication()
    }
}
