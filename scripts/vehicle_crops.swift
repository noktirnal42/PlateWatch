// Cuts the largest car/truck/bus out of every image under <src>/<class>/ using the vehicle detector, so a classifier
// learns the VEHICLE and not the scene (boats, bikes, backgrounds). Carries the manifest (author/licence) across.
// Usage: swiftc -O scripts/vehicle_crops.swift -o /tmp/vehicle_crops && /tmp/vehicle_crops <src> <out> <detector.mlpackage>
import Foundation
import CoreImage
import Vision
import CoreML
import ImageIO
import UniformTypeIdentifiers
guard CommandLine.arguments.count >= 4 else { print("usage: vehicle_crops <src dir> <out dir> <vehicle-detector.mlpackage>"); exit(2) }
let src = CommandLine.arguments[1], out = CommandLine.arguments[2]
let mURL = try! MLModel.compileModel(at: URL(fileURLWithPath: CommandLine.arguments[3]))
let vm = try! VNCoreMLModel(for: MLModel(contentsOf: mURL))
let ctx = CIContext(); let fm = FileManager.default
let want: Set<String> = ["car", "truck", "bus"]
var manifestIn: [String: [String: Any]] = [:]
if let d = try? Data(contentsOf: URL(fileURLWithPath: src + "/manifest.json")),
   let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] { for m in arr { if let f = m["file"] as? String { manifestIn[f] = m } } }
var manifest: [[String: Any]] = []; var kept = [String: Int](), seen = [String: Int]()
for cls in try! fm.contentsOfDirectory(atPath: src).sorted() {
  var isDir: ObjCBool = false
  guard fm.fileExists(atPath: "\(src)/\(cls)", isDirectory: &isDir), isDir.boolValue else { continue }
  try? fm.createDirectory(atPath: "\(out)/\(cls)", withIntermediateDirectories: true)
  for f in try! fm.contentsOfDirectory(atPath: "\(src)/\(cls)").sorted() where ["jpg","jpeg","png"].contains((f as NSString).pathExtension.lowercased()) {
    seen[cls, default: 0] += 1
    guard let ci = CIImage(contentsOf: URL(fileURLWithPath: "\(src)/\(cls)/\(f)")) else { continue }
    let req = VNCoreMLRequest(model: vm); req.imageCropAndScaleOption = .scaleFit
    guard (try? VNImageRequestHandler(ciImage: ci).perform([req])) != nil else { continue }
    let obs = (req.results as? [VNRecognizedObjectObservation] ?? []).filter { o in
      guard let l = o.labels.first?.identifier else { return false }
      return want.contains(l) && o.confidence >= 0.35 && o.boundingBox.width * o.boundingBox.height >= 0.04 }
    guard let best = obs.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) else { continue }
    let W = ci.extent.width, H = ci.extent.height, b = best.boundingBox
    var r = CGRect(x: b.minX*W, y: b.minY*H, width: b.width*W, height: b.height*H)
    r = r.insetBy(dx: -r.width*0.05, dy: -r.height*0.05).intersection(ci.extent)
    guard r.width >= 160, r.height >= 120 else { continue }
    let crop = ci.cropped(to: r)
    let cg = ctx.createCGImage(crop, from: crop.extent)!
    let name = ((f as NSString).deletingPathExtension) + ".jpg"
    let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(out)/\(cls)/\(name)") as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, cg, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary); CGImageDestinationFinalize(d)
    kept[cls, default: 0] += 1
    var m = manifestIn["\(cls)/\(f)"] ?? [:]; m["file"] = "\(cls)/\(name)"; m["class"] = cls; manifest.append(m)
  }
}
try! JSONSerialization.data(withJSONObject: manifest).write(to: URL(fileURLWithPath: out + "/manifest.json"))
print("seen", seen.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
print("crops", kept.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
