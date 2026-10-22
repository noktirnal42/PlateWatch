import SwiftUI

/// Offline help: available even when a camera operator or the documentation site is down.
struct HubHelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Label("PlateWatch Hub", systemImage: "building.columns").font(.largeTitle.bold())
                Text("A local console for public-fleet accountability.").font(.title3).foregroundStyle(.secondary)
                section("Start with a camera", icon: "antenna.radiowaves.left.and.right",
                        text: "Open Public feeds → Add cameras. Imports add camera metadata only. Review the image host's terms before allowing automated use. Every new host starts inactive. Camera counts can include unavailable or stale views.")
                section("Favorite or block", icon: "star",
                        text: "☆ pins a camera to Favorites. ⦸ blocks it on this Mac, stops its polling and previews, and hides it from All feeds and Favorites. Open Blocked and use ↶ to restore it. Stars and blocks survive relaunch; unblocking preserves your star.")
                section("What Live shows", icon: "eye",
                        text: "Select a camera and choose Open in Live. Snapshot feeds show the latest analysed still, refreshed at the camera's permitted interval. They are labelled Snapshot feed, not continuous video. Start camera uses a local or Continuity camera; Open video analyses frames from a file. Public HLS feeds use continuous frame analysis; real-stream validation remains in progress. Raw RTSP needs a separate decoder. The Overlays checkbox hides or shows detection boxes; tiny boxes reveal their labels on hover. Hiding overlays does not stop analysis.")
                section("Analysis in the background", icon: "cpu",
                        text: "Confirmed, unblocked snapshot cameras are analysed even when Live is closed. The dashboard counts completed public-feed frames this session. Requests share a per-host budget; busy analysis drops surplus frames. Polling means an active schedule, not proof that an image is current or that every frame was analysed. Fetched and Analysed times describe this Mac, not the camera's capture time.")
                section("Troubleshoot missing images", icon: "exclamationmark.triangle",
                        text: "Awaiting terms needs your review. Checking means robots.txt is being fetched. Host policy refused means an actual rule or HTTP 401/403/429 refusal. Policy temporarily unavailable means a lookup failed; it retries within a minute. Suspended means repeated failures or an unsupported transport. Refresh retries a selected snapshot and immediately rechecks an unavailable policy; use ⦸ for a persistently unavailable camera. Caltrans has a cited, tightly scoped fallback for its broken robots endpoint; other failures remain closed.")
                section("Fleet evidence, never a private-plate archive", icon: "hand.raised",
                        text: "Raw frames stay in memory. Only observations passing the fleet gate enter the outbox. Plate reading depends on the camera's location and jurisdiction; labels show vehicle class and fleet confidence, never plate text. A yellow box is a detection, not a confirmed fleet vehicle. A low-resolution traffic camera may support appearance analysis only.")
                section("Make the workspace yours", icon: "keyboard",
                        text: "Navigate menu shortcuts: ⌘1 Dashboard, ⌘2 Live, ⌘3 Public feeds, ⌘4 Cameras, ⌘5 Review, ⌘6 Models, ⌘7 Records and ⌘8 Settings. The Appearance menu offers System, Light and Dark for this console without changing your Mac. Feed names include their image host; hover for the full name and coarse area. Drag the divider to resize the preview.")
                section("Moderation", icon: "checkmark.shield",
                        text: "Available only to enrolled moderators. Sightings, takedowns and audit events load independently. Refresh works in every tab; an error keeps the last loaded rows visible. Approval publishes eligible fleet observations through the server's publication safeguards.")
                HStack {
                    Link("Documentation", destination: URL(string: "https://github.com/noktirnal42/PlateWatch/blob/main/docs/HUB-HANDOFF-2026-10-14.md")!)
                    Spacer()
                    Text("⌘0 reopens the console · ⌘? opens help").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(28)
        }.textSelection(.enabled)
    }

    private func section(_ title: String, icon: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon).font(.headline)
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Use native glass for the primary destination action; retain a standard control on older macOS.
struct HubPrimaryAction: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        content.buttonStyle(HUDProminentButtonStyle())
    }
}
