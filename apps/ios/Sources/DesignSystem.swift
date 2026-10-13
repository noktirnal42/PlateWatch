import SwiftUI

/// Shared visual vocabulary for PlateWatch. Kept small on purpose: a plate
/// look, a privacy chip, and a status pill. Every surface that shows a plate
/// or a sync state uses these so the app reads as one system.
enum PWStyle {
    /// Accent for fleet-classified detections. Matches the overlay border.
    static let fleet = Color.yellow
    static let queued = Color.orange
    static let synced = Color.green
    static let failing = Color.red
}

/// A plate rendered in a license-plate style: heavy monospaced caps with a
/// tracked gap, so it is scannable at a glance on a dense list.
struct PlateBadge: View {
    let text: String
    var compact = false

    var body: some View {
        Text(text.uppercased())
            .font(.system(compact ? .caption : .body, design: .monospaced).weight(.heavy))
            .tracking(compact ? 1 : 2)
            .foregroundStyle(.black.opacity(0.85))
            .padding(.horizontal, compact ? 6 : 10)
            .padding(.vertical, compact ? 2 : 4)
            .background(
                RoundedRectangle(cornerRadius: compact ? 4 : 6, style: .continuous)
                    .fill(Color(white: 0.96))
            )
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 4 : 6, style: .continuous)
                    .stroke(.black.opacity(0.35), lineWidth: 1)
            )
            .accessibilityLabel("Plate " + Array(text).map(String.init).joined(separator: " "))
    }
}

/// Reassures the user, on-screen, that nothing leaves the device by default.
struct PrivacyChip: View {
    var body: some View {
        Label("On-device", systemImage: "lock.shield.fill")
            .font(.caption.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: .capsule)
            .accessibilityHint("Frames are analyzed on this device. Only fleet-confirmed records can sync.")
    }
}

/// Outbox state as a colored dot + label.
struct SyncStatusPill: View {
    let retryCount: Int

    private var state: (label: String, color: Color, icon: String) {
        if retryCount == 0 {
            return ("Queued", PWStyle.queued, "clock")
        } else if retryCount < 5 {
            return ("Retrying · \(retryCount)", PWStyle.queued, "arrow.triangle.2.circlepath")
        } else {
            return ("Needs attention", PWStyle.failing, "exclamationmark.triangle.fill")
        }
    }

    var body: some View {
        Label(state.label, systemImage: state.icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(state.color)
            .labelStyle(.titleAndIcon)
            .accessibilityLabel("Sync status: \(state.label)")
    }
}
