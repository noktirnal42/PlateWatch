import SwiftUI
import UIKit

enum PWPhosphor: String, CaseIterable, Identifiable {
    case green, amber
    var id: String { rawValue }
    var title: String { self == .green ? "Green" : "Amber" }
    static let defaultsKey = "pwPhosphor"
    static var current: PWPhosphor { PWPhosphor(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .green }
}

/// Shared visual vocabulary for PlateWatch. Kept small on purpose: a plate
/// look, a privacy chip, and a status pill. Every surface that shows a plate
/// or a sync state uses these so the app reads as one system.
enum PWStyle {
    /// The "phosphor" glow of the HUD look: classic green by default, amber on request (About → Appearance). Used for fleet
    /// detections, accents and tint. Resolved at draw time; the app root re-ids itself when the setting changes.
    static let fleet = phosphor(green: (0x3DFF86, 0x0B7A3B), amber: (0xFFB000, 0x9A6200), darkOnly: true)
    /// Text/tint variant: bright phosphor on dark, a darker shade on light so contrast stays ≥ 5:1.
    static let fleetText = phosphor(green: (0x3DFF86, 0x0B7A3B), amber: (0xFFB000, 0x9A6200), darkOnly: false)
    static let ink = Color("PWInk")
    static let hairline = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.12, green: 0.16, blue: 0.21, alpha: 1) : UIColor(red: 0.84, green: 0.86, blue: 0.89, alpha: 1) })
    static let base = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.035, green: 0.047, blue: 0.063, alpha: 1) : UIColor(red: 0.957, green: 0.965, blue: 0.973, alpha: 1) })

    private static func phosphor(green: (UInt32, UInt32), amber: (UInt32, UInt32), darkOnly: Bool) -> Color {
        Color(uiColor: UIColor { trait in
            let pair = PWPhosphor.current == .amber ? amber : green
            let dark = trait.userInterfaceStyle == .dark
            let hex = (dark || darkOnly) ? pair.0 : pair.1
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
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
            .accessibilityHint("Frames are analyzed on this device. Only fleet-scoped structured observations enter the moderation queue.")
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
        } else if retryCount < 8 {
            return ("Needs attention", PWStyle.failing, "exclamationmark.triangle.fill")
        } else {
            return ("Retries paused", PWStyle.failing, "pause.circle.fill")
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

/// Branded empty state: the plate-in-viewfinder mark over a short, plain
/// explanation. Used wherever a list has nothing to show yet.
struct PWEmptyState: View {
    let title: String
    let message: String
    var systemImage: String?

    var body: some View {
        VStack(spacing: 14) {
            Image("LaunchLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 84, height: 84)
                .padding(10)
                .background(Color("LaunchBackground"), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(.black)
                            .frame(width: 28, height: 28)
                            .background(PWStyle.fleet, in: .circle)
                            .offset(x: 6, y: 6)
                    }
                }
                .accessibilityHidden(true)
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .accessibilityElement(children: .combine)
    }
}

/// Editorial header used across data screens; native lists carry the actions.
struct PWSectionIntro: View {
    let eyebrow: String
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label { Text(eyebrow.uppercased()).font(.system(size: 11, weight: .semibold, design: .monospaced)).tracking(1.6) } icon: { Image(systemName: systemImage) }
                .foregroundStyle(PWStyle.fleetText)
            Text(title).font(.title2.weight(.bold))
            Text(message).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}


// MARK: - HUD look (phosphor console)

/// Four viewfinder corner brackets.
struct PWCornerBrackets: Shape {
    var length: CGFloat = 12
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let l = min(length, min(rect.width, rect.height) / 2)
        for (x, y, dx, dy) in [(rect.minX, rect.minY, 1.0, 1.0), (rect.maxX, rect.minY, -1.0, 1.0),
                               (rect.minX, rect.maxY, 1.0, -1.0), (rect.maxX, rect.maxY, -1.0, -1.0)] {
            p.move(to: CGPoint(x: x + dx * l, y: y)); p.addLine(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x, y: y + dy * l))
        }
        return p
    }
}

/// A faint coordinate grid behind each screen. Static; stronger contrast mode drops it.
struct PWBackdrop: View {
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        ZStack {
            PWStyle.base
            if contrast != .increased {
                Canvas { context, size in
                    var path = Path()
                    var x: CGFloat = 0
                    while x <= size.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)); x += 36 }
                    var y: CGFloat = 0
                    while y <= size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += 36 }
                    context.stroke(path, with: .color(PWStyle.fleet.opacity(0.05)), lineWidth: 0.5)
                }
                RadialGradient(colors: [PWStyle.fleet.opacity(0.08), .clear], center: .topLeading, startRadius: 0, endRadius: 420)
            }
        }
        .ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}

extension View {
    /// Screen chrome: hide list backgrounds and show the HUD backdrop.
    func pwScreen() -> some View { scrollContentBackground(.hidden).background(PWBackdrop()) }

    /// A bordered HUD card with phosphor corner brackets.
    func pwPanel(cornerRadius: CGFloat = 12) -> some View { modifier(PWPanel(cornerRadius: cornerRadius)) }
}

struct PWPanel: ViewModifier {
    var cornerRadius: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Color(.secondarySystemBackground).opacity(0.85)))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(contrast == .increased ? Color.primary : PWStyle.hairline, lineWidth: contrast == .increased ? 1.5 : 1))
            .overlay(PWCornerBrackets(length: 9).stroke(PWStyle.fleetText.opacity(contrast == .increased ? 1 : 0.75), lineWidth: contrast == .increased ? 2 : 1.2).padding(3))
    }
}

/// Spaced monospaced overline, e.g. "FLEET SIGHTINGS".
struct PWLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 11, weight: .semibold, design: .monospaced)).tracking(1.6).foregroundStyle(PWStyle.fleetText)
    }
}

/// Root theme: phosphor tint, dark by default (About → Appearance can follow the system), list backgrounds hidden.
struct PWTheme: ViewModifier {
    @AppStorage(PWPhosphor.defaultsKey) private var phosphor = PWPhosphor.green.rawValue
    @AppStorage("pwAppearance") private var appearance = "dark"
    func body(content: Content) -> some View {
        content
            .tint(PWStyle.fleetText)
            .preferredColorScheme(appearance == "dark" ? .dark : nil)
            .scrollContentBackground(.hidden)
            .id(phosphor)
    }
}
extension View { func pwTheme() -> some View { modifier(PWTheme()) } }
