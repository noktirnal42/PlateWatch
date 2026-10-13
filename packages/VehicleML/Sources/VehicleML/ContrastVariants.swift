import CoreGraphics
import CoreImage
import Foundation

/// Dark-on-dark lettering (a black SUV with charcoal "WALTHAM POLICE" on the tailgate) is
/// invisible to text recognition on the raw pixels. Stretching the dark range of a region
/// and scaling it up makes the same text legible — measured on a real photo, a levels
/// stretch at 2× recovered "WALTHAM" that no treatment of the full frame did.
enum ContrastVariants {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Mean luminance 0…1 of a region (sampled from a 16×16 downscale).
    static func meanLuminance(_ image: CGImage) -> Double {
        let ci = CIImage(cgImage: image)
        let avg = ci.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: ci.extent)])
        var px = [UInt8](repeating: 0, count: 4)
        context.render(avg, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return (0.2126 * Double(px[0]) + 0.7152 * Double(px[1]) + 0.0722 * Double(px[2])) / 255
    }

    /// Grayscale levels stretch (`out = in × gain + bias`) after an optional Lanczos upscale.
    static func stretched(_ image: CGImage, scale: Double, gain: Double, bias: Double) -> CGImage? {
        var ci = CIImage(cgImage: image)
        if scale != 1 {
            ci = ci.applyingFilter("CILanczosScaleTransform",
                                   parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0])
        }
        ci = ci.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
                "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0)])
        return context.createCGImage(ci, from: ci.extent)
    }

    /// Stretch settings that worked on dark regions (gain 2–4 at 2×; stronger washes text out).
    static let darkRecipes: [(gain: Double, bias: Double)] = [(2.5, -0.08), (3.5, -0.2)]
    static let darkThreshold = 0.38
}
