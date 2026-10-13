#!/usr/bin/env swift
// Generates the PlateWatch app icon and launch mark (CoreGraphics only).
// Usage: swift scripts/make-brand-assets.swift apps/ios/Sources/Assets.xcassets
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let ink = CGColor(red: 0x0E / 255, green: 0x11 / 255, blue: 0x16 / 255, alpha: 1)
let amber = CGColor(red: 1, green: 0xC2 / 255, blue: 0x1A / 255, alpha: 1)

func render(size: Int, background: Bool, to url: URL) {
    let s = CGFloat(size) / 512
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s, y: s)
    // Flip to a top-left origin so coordinates match the SVG mark.
    ctx.translateBy(x: 0, y: 512); ctx.scaleBy(x: 1, y: -1)

    if background { ctx.setFillColor(ink); ctx.fill(CGRect(x: 0, y: 0, width: 512, height: 512)) }

    ctx.setStrokeColor(amber); ctx.setLineWidth(26); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    func bracket(_ pts: [(CGFloat, CGFloat)]) {
        ctx.beginPath(); ctx.move(to: CGPoint(x: pts[0].0, y: pts[0].1))
        for p in pts.dropFirst() { ctx.addLine(to: CGPoint(x: p.0, y: p.1)) }
        ctx.strokePath()
    }
    bracket([(112, 180), (112, 132), (132, 112), (180, 112)])
    bracket([(332, 112), (380, 112), (400, 132), (400, 180)])
    bracket([(400, 332), (400, 380), (380, 400), (332, 400)])
    bracket([(180, 400), (132, 400), (112, 380), (112, 332)])

    let plate = CGPath(roundedRect: CGRect(x: 136, y: 180, width: 240, height: 152),
                       cornerWidth: 20, cornerHeight: 20, transform: nil)
    ctx.setFillColor(amber); ctx.addPath(plate); ctx.fillPath()
    ctx.setFillColor(CGColor(red: 0.055, green: 0.067, blue: 0.086, alpha: 0.16))
    ctx.fill(CGRect(x: 136, y: 196, width: 240, height: 14))
    ctx.setFillColor(CGColor(red: 0.055, green: 0.067, blue: 0.086, alpha: 0.55))
    for x in [162.0, 350.0] { ctx.fillEllipse(in: CGRect(x: x - 5, y: 190, width: 10, height: 10)) }

    ctx.setStrokeColor(ink); ctx.setLineWidth(22)
    bracket([(186, 308), (186, 232)])
    ctx.beginPath(); ctx.move(to: CGPoint(x: 186, y: 232)); ctx.addLine(to: CGPoint(x: 214, y: 232))
    ctx.addArc(center: CGPoint(x: 214, y: 253), radius: 21, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
    ctx.addLine(to: CGPoint(x: 186, y: 274)); ctx.strokePath()
    bracket([(266, 232), (282, 308), (304, 252), (326, 308), (342, 232)])

    let image = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("write failed: \(url.path)") }
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Assets.xcassets")
let fm = FileManager.default
func write(_ path: String, _ json: String) throws {
    let url = root.appendingPathComponent(path)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try json.write(to: url, atomically: true, encoding: .utf8)
}
func color(_ name: String, light: String, dark: String) throws {
    func comps(_ hex: String) -> String {
        let v = Int(hex, radix: 16)!
        return "\"red\":\"\(String(format: "%.3f", Double((v >> 16) & 255) / 255))\",\"green\":\"\(String(format: "%.3f", Double((v >> 8) & 255) / 255))\",\"blue\":\"\(String(format: "%.3f", Double(v & 255) / 255))\",\"alpha\":\"1.000\""
    }
    try write("\(name).colorset/Contents.json", """
    {"colors":[
      {"color":{"color-space":"srgb","components":{\(comps(light))}},"idiom":"universal"},
      {"appearances":[{"appearance":"luminosity","value":"dark"}],"color":{"color-space":"srgb","components":{\(comps(dark))}},"idiom":"universal"}
    ],"info":{"author":"xcode","version":1}}
    """)
}

try write("Contents.json", #"{"info":{"author":"xcode","version":1}}"#)
try write("AppIcon.appiconset/Contents.json", """
{"images":[{"filename":"AppIcon-1024.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}
""")
render(size: 1024, background: true, to: root.appendingPathComponent("AppIcon.appiconset/AppIcon-1024.png"))
try write("LaunchLogo.imageset/Contents.json", """
{"images":[{"filename":"LaunchLogo.png","idiom":"universal","scale":"1x"},{"filename":"LaunchLogo@2x.png","idiom":"universal","scale":"2x"},{"filename":"LaunchLogo@3x.png","idiom":"universal","scale":"3x"}],"info":{"author":"xcode","version":1}}
""")
for (suffix, px) in [("", 120), ("@2x", 240), ("@3x", 360)] {
    render(size: px, background: false, to: root.appendingPathComponent("LaunchLogo.imageset/LaunchLogo\(suffix).png"))
}
try color("AccentColor", light: "9A6A00", dark: "FFC21A")
try color("LaunchBackground", light: "0E1116", dark: "0E1116")
try color("PWInk", light: "0E1116", dark: "F1EFE8")
try color("PWAmber", light: "FFC21A", dark: "FFC21A")
print("wrote \(root.path)")
