import AppKit
import SwiftUI

/// The Hub's visual language: a dark, low-glare operations console with a single cyan accent, green for "live/healthy",
/// amber for "waiting", red for faults, monospaced readouts and thin corner brackets that echo the target boxes on video.
/// Pattern and palette follow TrafficView's DESIGN.md (re-implemented). Everything has a light-mode value, respects Reduce
/// Motion / Increase Contrast through the system, and carries no information by colour alone.
enum Phosphor: String, CaseIterable, Identifiable {
    case green, amber
    var id: String { rawValue }
    var title: String { self == .green ? "Green" : "Amber" }
    static let defaultsKey = "hubPhosphor"
    static var current: Phosphor { Phosphor(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .green }
}

enum HubTheme {
    static let base = adaptive(dark: 0x090C10, light: 0xF4F6F8)
    static let raised = adaptive(dark: 0x0E131A, light: 0xFFFFFF)
    static let inset = adaptive(dark: 0x06090C, light: 0xE7EBEF)
    static let hairline = adaptive(dark: 0x1E2A35, light: 0xD5DCE3)
    static let textPrimary = adaptive(dark: 0xE8EDF2, light: 0x11161C)
    static let textSecondary = adaptive(dark: 0x9AA7B4, light: 0x4B5865)
    static let textTertiary = adaptive(dark: 0x7F8D9A, light: 0x6A7783)
    /// The "phosphor" colour of the console: classic green by default, amber on request (Settings → Appearance).
    /// Resolved each time the colour is drawn, so a rebuild (`ConsoleView` re-ids itself on change) picks up a switch.
    static let accent = phosphorColor(green: (dark: 0x3DFF86, light: 0x0B7A3B), amber: (dark: 0xFFB000, light: 0x9A6200))
    /// Target-acquired colour for fleet hits: contrasts with the phosphor (amber on green, green on amber).
    static let hot = phosphorColor(green: (dark: 0xFFB000, light: 0x9A6200), amber: (dark: 0x3DFF86, light: 0x0B7A3B))
    /// "Healthy / live" reads as the phosphor itself.
    static var live: Color { accent }
    /// "Waiting / connecting": amber on green, pale ice on amber.
    static let amber = phosphorColor(green: (dark: 0xFFB000, light: 0x9A6200), amber: (dark: 0xBFE9FF, light: 0x1F62C4))
    static let alert = adaptive(dark: 0xFF5C5C, light: 0xC62828)

    static func phosphorColor(green: (dark: UInt32, light: UInt32), amber: (dark: UInt32, light: UInt32)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let pair = Phosphor.current == .amber ? amber : green
            let hex = isDark ? pair.dark : pair.light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }

    static func adaptive(dark: UInt32, light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }
}

/// Four corner brackets, like a viewfinder. `length` is the size of each arm.
struct CornerBrackets: Shape {
    var length: CGFloat = 14
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

/// A raised console panel: hairline border, faint top-lit gradient, accent corner brackets.
struct HUDPanel: ViewModifier {
    var accent: Color = HubTheme.accent
    var cornerRadius: CGFloat = 10
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(LinearGradient(colors: [HubTheme.raised, HubTheme.raised.opacity(0.82)], startPoint: .top, endPoint: .bottom)))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(HubTheme.hairline, lineWidth: 1))
            .overlay(CornerBrackets(length: 9).stroke(accent.opacity(0.75), lineWidth: 1.2).padding(3))
    }
}

extension View {
    func hudPanel(accent: Color = HubTheme.accent, cornerRadius: CGFloat = 10) -> some View { modifier(HUDPanel(accent: accent, cornerRadius: cornerRadius)) }
}

/// Small spaced-out monospaced overline, e.g. "SYSTEM STATUS".
struct HUDLabel: View {
    let text: String
    var color: Color = HubTheme.textTertiary
    init(_ text: String, color: Color = HubTheme.textTertiary) { self.text = text; self.color = color }
    var body: some View {
        Text(text.uppercased()).font(HubTheme.mono(10, .medium)).tracking(1.6).foregroundStyle(color)
    }
}

/// Status chip: dot + monospaced label. Colour is paired with text, never alone.
struct HUDStatusChip: View {
    let text: String
    let color: Color
    var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
                .opacity(pulsing && !reduceMotion ? (on ? 0.35 : 1) : 1)
                .animation(pulsing && !reduceMotion ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: on)
            Text(text.uppercased()).font(HubTheme.mono(10, .semibold)).tracking(1.2).foregroundStyle(color)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(Color.black.opacity(0.35)))
        .overlay(Capsule().stroke(color.opacity(0.55), lineWidth: 0.8))
        .onAppear { on = true }
        .accessibilityElement(children: .ignore).accessibilityLabel(text)
    }
}

/// A faint coordinate grid for pane backgrounds. Static; costs one Canvas draw.
struct HUDBackdrop: View {
    var body: some View {
        ZStack {
            HubTheme.base
            Canvas { context, size in
                let step: CGFloat = 40
                var path = Path()
                var x: CGFloat = 0
                while x <= size.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)); x += step }
                var y: CGFloat = 0
                while y <= size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += step }
                context.stroke(path, with: .color(HubTheme.accent.opacity(0.045)), lineWidth: 0.5)
            }
            RadialGradient(colors: [HubTheme.accent.opacity(0.07), .clear], center: .topLeading, startRadius: 0, endRadius: 520)
        }
        .ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}


/// Replaces `GroupBox` everywhere under it: spaced overline title in a HUD panel.
struct HUDGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label.font(HubTheme.mono(10, .medium)).textCase(.uppercase).tracking(1.6).foregroundStyle(HubTheme.textTertiary)
            configuration.content
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .hudPanel()
    }
}

/// Default button look: dark glass, phosphor outline and label, brightens on hover, dims when disabled.
struct HUDButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(enabled ? HubTheme.accent : HubTheme.textTertiary)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(HubTheme.accent.opacity(configuration.isPressed ? 0.28 : (hover && enabled ? 0.16 : 0.07))))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(HubTheme.accent.opacity(enabled ? 0.55 : 0.2), lineWidth: 0.8))
            .onHover { hover = $0 }
    }
}

/// Sidebar row: phosphor bar and tint on the selected pane, monospaced small caps feel without losing legibility.
struct HUDSidebarRow: View {
    let title: String
    let icon: String
    let selected: Bool
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 13)).frame(width: 18)
                .foregroundStyle(selected ? HubTheme.accent : HubTheme.textSecondary)
            Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? HubTheme.textPrimary : HubTheme.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? HubTheme.accent.opacity(0.13) : .clear))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1).fill(selected ? HubTheme.accent : .clear).frame(width: 2.5, height: 16)
                .shadow(color: HubTheme.accent.opacity(selected ? 0.7 : 0), radius: 4)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}


/// Primary action: solid phosphor fill with dark label (default-action emphasis).
struct HUDProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle((scheme == .dark ? Color.black : Color.white).opacity(enabled ? 0.92 : 0.6))
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(HubTheme.accent.opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)))
            .shadow(color: HubTheme.accent.opacity(enabled ? 0.35 : 0), radius: 6)
    }
}
