import CoreVideo
import Foundation

/// A conservative, on-device colour cue for a vehicle crop. This is a
/// fallback attribute only: it is never used as fleet evidence and is not a
/// replacement for the planned licensed make/model/colour model.
public struct VehicleColorCue: Sendable, Equatable {
    public let color: String
    public let confidence: Double

    public init(color: String, confidence: Double) {
        self.color = color
        self.confidence = confidence
    }
}

public enum VehicleColorClassifier {
    /// Classifies an RGB mean. Keeping this pure makes the thresholds
    /// deterministic and lets tests avoid camera or photo-library fixtures.
    public static func classify(red: Double, green: Double, blue: Double) -> VehicleColorCue? {
        let r = min(1, max(0, red)), g = min(1, max(0, green)), b = min(1, max(0, blue))
        let maximum = max(r, g, b), minimum = min(r, g, b), spread = maximum - minimum
        guard maximum >= 0.08 else { return VehicleColorCue(color: "black", confidence: 0.72) }
        if maximum > 0.78, spread < 0.10 { return VehicleColorCue(color: "white", confidence: 0.84) }
        if spread < 0.09 { return VehicleColorCue(color: maximum < 0.34 ? "charcoal" : "gray", confidence: 0.68) }

        let hue: Double
        if maximum == r { hue = ((g - b) / spread).truncatingRemainder(dividingBy: 6) / 6 }
        else if maximum == g { hue = ((b - r) / spread + 2) / 6 }
        else { hue = ((r - g) / spread + 4) / 6 }
        let normalizedHue = hue < 0 ? hue + 1 : hue
        let color: String
        switch normalizedHue {
        case 0.04..<0.13 where r > b * 1.35: color = "orange"
        case 0.13..<0.19: color = "yellow"
        case 0.19..<0.45: color = "green"
        case 0.45..<0.72: color = "blue"
        case 0.72..<0.92: color = "purple"
        default: color = "red"
        }
        let confidence = min(0.86, max(0.42, 0.42 + spread * 0.8))
        return VehicleColorCue(color: color, confidence: confidence)
    }

    /// Samples a normalized vehicle box from a BGRA or RGBA 8-bit buffer.
    /// The result is deliberately a coarse cue; no image is retained.
    public static func classify(_ pixelBuffer: CVPixelBuffer, box: (x: Double, y: Double, width: Double, height: Double)) -> VehicleColorCue? {
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        let x0 = max(0, min(width - 1, Int(box.x * Double(width))))
        let x1 = max(x0 + 1, min(width, Int((box.x + box.width) * Double(width))))
        let y0 = max(0, min(height - 1, Int((1 - box.y - box.height) * Double(height))))
        let y1 = max(y0 + 1, min(height, Int((1 - box.y) * Double(height))))
        guard x1 > x0, y1 > y0 else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let rowStride = CVPixelBufferGetBytesPerRow(pixelBuffer), stepX = max(1, (x1 - x0) / 12), stepY = max(1, (y1 - y0) / 12)
        var r = 0.0, g = 0.0, b = 0.0, count = 0.0
        for y in stride(from: y0, to: y1, by: stepY) {
            for x in stride(from: x0, to: x1, by: stepX) {
                let p = base[y * rowStride + x * 4]
                // CameraPreview and CoreVideo's common 32BGRA format are B,G,R,A.
                b += Double(p) / 255; g += Double(base[y * rowStride + x * 4 + 1]) / 255
                r += Double(base[y * rowStride + x * 4 + 2]) / 255; count += 1
            }
        }
        return count > 0 ? classify(red: r / count, green: g / count, blue: b / count) : nil
    }
}
