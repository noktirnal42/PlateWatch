// Tags every image under <root>/<class>/ with Apple's built-in image classifier (VNClassifyImageRequest) and writes
// [{class, file, tags:[{l,c}]}] JSON. Used to filter crawled training images (docs/MODEL-TRAINING.md §7).
// Usage: swiftc -O scripts/tag_images.swift -o /tmp/tag_images && /tmp/tag_images <root> <out.json>
import Foundation
import Vision
let root = CommandLine.arguments[1]
let fm = FileManager.default
var out: [[String: Any]] = []
for cls in try! fm.contentsOfDirectory(atPath: root).sorted() {
  var isDir: ObjCBool = false
  guard fm.fileExists(atPath: root + "/" + cls, isDirectory: &isDir), isDir.boolValue else { continue }
  for f in try! fm.contentsOfDirectory(atPath: root + "/" + cls).sorted() where f.lowercased().hasSuffix(".jpg") || f.lowercased().hasSuffix(".jpeg") || f.lowercased().hasSuffix(".png") {
    let url = URL(fileURLWithPath: root + "/" + cls + "/" + f)
    let req = VNClassifyImageRequest()
    guard (try? VNImageRequestHandler(url: url).perform([req])) != nil else { continue }
    let top = (req.results ?? []).filter { $0.confidence > 0.05 }.prefix(8).map { ["l": $0.identifier, "c": Double(String(format: "%.2f", $0.confidence))!] as [String: Any] }
    out.append(["class": cls, "file": f, "tags": top])
  }
}
try! JSONSerialization.data(withJSONObject: out).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
print(out.count)
