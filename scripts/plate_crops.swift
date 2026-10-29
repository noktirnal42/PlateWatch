// Cuts the plate out of every image under <src>/<State>/ with the plate detector so the state classifier learns the
// plate DESIGN, not the car or scene (docs/PLATE-STATE-CLASSIFIER-SPEC.md §3). If no plate is found but the image
// is already plate-shaped (aspect 1.5–2.4, e.g. a flat scan) it is kept whole; anything else is skipped.
// Usage: swiftc -O scripts/plate_crops.swift -o /tmp/plate_crops && /tmp/plate_crops <src> <out> <plate-detector.mlmodel>
import Foundation
import CoreImage
import Vision
import CoreML
import ImageIO
import UniformTypeIdentifiers
guard CommandLine.arguments.count >= 4 else { print("usage: plate_crops <src dir> <out dir> <plate-detector.mlmodel>"); exit(2) }
let src = CommandLine.arguments[1], out = CommandLine.arguments[2]
let mURL = try! MLModel.compileModel(at: URL(fileURLWithPath: CommandLine.arguments[3]))
let vm = try! VNCoreMLModel(for: MLModel(contentsOf: mURL))
let ctx = CIContext(); let fm = FileManager.default
var manifestIn: [String: [String: Any]] = [:]
if let d = try? Data(contentsOf: URL(fileURLWithPath: src + "/manifest.json")),
   let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] { for m in arr { if let f = m["file"] as? String { manifestIn[f] = m } } }
var manifest: [[String: Any]] = []; var cropped = 0, whole = 0, skipped = 0
for cls in try! fm.contentsOfDirectory(atPath: src).sorted() {
  var isDir: ObjCBool = false
  guard fm.fileExists(atPath: "\(src)/\(cls)", isDirectory: &isDir), isDir.boolValue else { continue }
  for f in try! fm.contentsOfDirectory(atPath: "\(src)/\(cls)").sorted() where ["jpg","jpeg","png"].contains((f as NSString).pathExtension.lowercased()) {
    guard let ci = CIImage(contentsOf: URL(fileURLWithPath: "\(src)/\(cls)/\(f)")) else { skipped += 1; continue }
    let req = VNCoreMLRequest(model: vm); req.imageCropAndScaleOption = .scaleFit
    var rect: CGRect?
    if (try? VNImageRequestHandler(ciImage: ci).perform([req])) != nil,
       let best = (req.results as? [VNRecognizedObjectObservation] ?? []).filter({ $0.confidence >= 0.3 }).max(by: { $0.confidence < $1.confidence }) {
      let W = ci.extent.width, H = ci.extent.height, b = best.boundingBox
      var r = CGRect(x: b.minX*W, y: b.minY*H, width: b.width*W, height: b.height*H)
      r = r.insetBy(dx: -r.width*0.08, dy: -r.height*0.08).intersection(ci.extent)
      if r.width >= 90, r.height >= 40 { rect = r }
    }
    let aspect = ci.extent.width / ci.extent.height
    let image: CIImage
    if let rect { image = ci.cropped(to: rect); cropped += 1 }
    else if (1.5...2.4).contains(aspect) { image = ci; whole += 1 }
    else { skipped += 1; continue }
    guard let cg = ctx.createCGImage(image, from: image.extent) else { skipped += 1; continue }
    try? fm.createDirectory(atPath: "\(out)/\(cls)", withIntermediateDirectories: true)
    let name = ((f as NSString).deletingPathExtension) + ".jpg"
    let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(out)/\(cls)/\(name)") as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, cg, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary); CGImageDestinationFinalize(d)
    if var m = manifestIn["\(cls)/\(f)"] { m["file"] = "\(cls)/\(name)"; manifest.append(m) }
  }
  print(cls, terminator: " ")
}
let data = try! JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
try! data.write(to: URL(fileURLWithPath: out + "/manifest.json"))
print("\ncropped \(cropped), kept whole \(whole), skipped \(skipped)")
