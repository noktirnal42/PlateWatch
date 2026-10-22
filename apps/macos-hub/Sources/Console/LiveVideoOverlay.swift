import AVFoundation
import AppKit
import PlateKit
import SwiftUI

/// Hosts an `AVPlayerLayer` for a decoder-owned player. The decoder keeps playing whether or not this view exists.
/// Pattern taken from TrafficView's `VideoSurface` (re-implemented; nothing copied).
struct LiveVideoSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> LivePlayerView { LivePlayerView(player: player) }
    func updateNSView(_ view: LivePlayerView, context: Context) { view.player = player }
}

final class LivePlayerView: NSView {
    private let playerLayer = AVPlayerLayer()
    var player: AVPlayer? { didSet { playerLayer.player = player } }

    init(player: AVPlayer) {
        self.player = player
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        playerLayer.player = player
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}

/// Target boxes drawn in normalised frame space and mapped through the aspect-fit rectangle of the video.
/// Each box has a dark casing under a coloured stroke so it reads on bright sky and dark asphalt (TrafficView's
/// two-stroke treatment); fleet hits are green, other vehicles cyan; chips are dark glass with a colour-keyed edge.
struct VehicleBoxCanvas: View {
    let boxes: [LiveFrameResult.Box]
    /// Pixel size of the analysed frame (sets the aspect ratio of the video area).
    let frameSize: CGSize
    /// Fade the boxes out when the analysis they came from is older than this (they would no longer sit on the vehicles).
    var staleAfter: TimeInterval = 4
    var updatedAt: Date = .now
    /// Extrapolate box positions between analysed frames (moving live video only).
    var glide = false
    static let maxGlide: TimeInterval = 0.35

    /// Vehicles use the console's phosphor colour; fleet hits use its contrast colour (amber on green, green on amber).
    static var vehicle: Color { HubTheme.accent }
    static var fleet: Color { HubTheme.hot }

    var body: some View {
        TimelineView(.animation(minimumInterval: glide ? 1.0 / 30 : 1)) { timeline in
            let age = timeline.date.timeIntervalSince(updatedAt)
            // Boxes are measured ~4x/s; carry each along its tracked velocity until the next measurement. Capped so a stalled
            // stream's boxes never wander far from where the vehicle last was.
            let lead = glide ? min(max(age, 0), Self.maxGlide) : 0
            Canvas { context, size in
                guard frameSize.width > 0, frameSize.height > 0 else { return }
                let video = Self.aspectFit(content: frameSize, in: size)
                for box in boxes {
                    let rect = CGRect(x: video.minX + (box.rect.x + box.vx * lead) * video.width,
                                      y: video.minY + (box.rect.y + box.vy * lead) * video.height,
                                      width: box.rect.width * video.width, height: box.rect.height * video.height)
                    Self.draw(box, in: rect, video: video, context: &context)
                }
            }
            .opacity(age > staleAfter ? 0.35 : 1)
            .animation(.easeOut(duration: 0.2), value: age > staleAfter)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(boxes.isEmpty ? "No vehicles detected" : boxes.map(\.label).joined(separator: ". "))
    }

    private static func draw(_ box: LiveFrameResult.Box, in rect: CGRect, video: CGRect, context: inout GraphicsContext) {
        let color = box.isFleet ? fleet : vehicle
        let path = Path(roundedRect: rect, cornerRadius: 4)
        context.stroke(path, with: .color(.black.opacity(0.55)), lineWidth: box.isFleet ? 4.5 : 3.5)
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: box.isFleet ? 2.5 : 2, dash: box.uncertain ? [6, 4] : []))
        guard rect.width >= 56 else { return }

        let lines = box.label.components(separatedBy: " · ").filter { !$0.isEmpty }
        let shown = Array(lines.prefix(3))
        let lineHeight: CGFloat = 14
        let chipHeight = lineHeight * CGFloat(shown.count) + 8
        let chipWidth = min(max(rect.width, 96), CGFloat(shown.map(\.count).max() ?? 0) * 6.4 + 16)
        var origin = CGPoint(x: rect.minX, y: rect.minY - chipHeight - 3)
        if origin.y < video.minY { origin.y = rect.minY + 3 }                       // no room above: sit inside the box
        origin.x = min(max(origin.x, video.minX), video.maxX - chipWidth)             // never leave the picture
        let chip = CGRect(origin: origin, size: CGSize(width: chipWidth, height: chipHeight))
        context.fill(Path(roundedRect: chip, cornerRadius: 5), with: .color(Color(red: 0x0A / 255, green: 0x0D / 255, blue: 0x11 / 255).opacity(0.85)))
        context.stroke(Path(roundedRect: chip, cornerRadius: 5), with: .color(color.opacity(0.85)), lineWidth: 0.75)
        for (index, line) in shown.enumerated() {
            context.draw(
                Text(line).font(.system(size: 11, weight: index == 0 ? .semibold : .regular, design: .rounded))
                    .foregroundStyle(index == 0 ? Color(white: 0.92) : Color(white: 0.66)),
                at: CGPoint(x: chip.minX + 8, y: chip.minY + 4 + CGFloat(index) * lineHeight), anchor: .topLeading)
        }
    }

    static func aspectFit(content: CGSize, in container: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0, container.width > 0, container.height > 0 else { return CGRect(origin: .zero, size: container) }
        let scale = min(container.width / content.width, container.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
    }
}
