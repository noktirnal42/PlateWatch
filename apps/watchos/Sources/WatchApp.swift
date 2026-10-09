import SwiftUI

@main
struct PlateWatchWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WatchRootView()
        }
    }
}

/// watchOS is intentionally camera-less: this app is the alert-and-log
/// companion. CKQuerySubscription pushes wake it when a watchlist vehicle is
/// fleet-confirmed nearby.
struct WatchRootView: View {
    @State private var hits: [String] = [] // fed by push handler (CloudKit)

    var body: some View {
        NavigationStack {
            List {
                Section("Recent fleet hits") {
                    if hits.isEmpty {
                        Text("No alerts yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(hits, id: \.self) { Text($0) }
                    }
                }
                NavigationLink("Quick log") {
                    QuickLogView()
                }
            }
            .navigationTitle("PlateWatch")
        }
    }
}

/// Dictation-based field note: "Black and white unit 8823 on 5th" → text →
/// outbox as an unverified community observation (lowest confidence tier).
struct QuickLogView: View {
    @State private var note = ""
    @State private var saved = false

    var body: some View {
        VStack(spacing: 12) {
            TextField("Say or type what you saw…", text: $note)
            Button("Log it") {
                // Persist to PlateSync outbox as a manual, unverified note.
                saved = true
            }
            .disabled(note.trimmingCharacters(in: .whitespaces).isEmpty)
            if saved {
                Label("Queued", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            }
        }
        .padding()
    }
}
