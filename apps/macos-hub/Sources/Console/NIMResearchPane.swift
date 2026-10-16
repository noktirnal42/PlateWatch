import AppKit
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers
import NIMKit

/// Explicit, in-memory public research. No access to queue images or record acceptance.
struct NIMResearchPane: View {
    enum Mode: String, CaseIterable { case search = "Cited search", document = "Document extraction", vision = "Vehicle benchmark" }
    @State private var mode: Mode = .search
    @State private var query = ""
    @State private var source = ""
    @State private var page = 1
    @State private var passage = ""
    @State private var passages: [PublicPassage] = []
    @State private var ranked: [RankedPassage] = []
    @State private var image: NSImage?
    @State private var jpeg: Data?
    @State private var truth = ""
    @State private var exhaustive = false
    @State private var approved = false
    @State private var running = false
    @State private var status = "Ready · add NVIDIA key in Settings"
    @State private var output = ""
    @State private var work: Task<Void, Never>?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("NVIDIA public research").font(.title2.bold())
                Text("Hosted processing sends selected content to NVIDIA. Use public or licensed material approved for this use. Results are research candidates; no records are accepted or published. Inputs and results stay in this pane until you export or close the app.")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("Workflow", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).disabled(running)
                    .onChange(of: mode) { _, _ in output = ""; ranked = []; approved = false }
                TextField("Original HTTPS source citation", text: $source)
                Stepper("Source page: \(page)", value: $page, in: 1...100_000)
                    .onChange(of: page) { _, _ in jpeg = nil; image = nil; approved = false; output = "" }
                if mode == .search {
                    TextEditor(text: $passage).frame(height: 100).border(.quaternary).accessibilityLabel("Public source passage")
                    HStack {
                        Button("Add cited passage (\(passages.count)/24)", action: addPassage).disabled(running || passages.count >= 24)
                        Button("Clear corpus") { passages = []; ranked = []; output = ""; approved = false }.disabled(running)
                    }
                    ForEach(passages) { item in
                        HStack {
                            Text(item.text).lineLimit(1)
                            Link("Source · p. \(item.page)", destination: item.sourceURL)
                            Button("Remove") { passages.removeAll { $0.id == item.id }; ranked = []; approved = false }.disabled(running)
                        }.font(.caption)
                    }
                    TextField("Search these public passages", text: $query)
                } else {
                    Button("Choose public image or PDF page…", action: chooseImage).disabled(running)
                    if let image {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 260)
                        Text("Prepared JPEG: \((jpeg?.count ?? 0) / 1000) KB · only this preview is sent").font(.caption)
                    }
                    Text(mode == .document ? "Nemotron Parse extracts one selected page. Check original text/tables before using any field." : "Nemotron 3.5 Super VL candidate boxes for a separate vehicle benchmark. This does not change Live detection. Export the response for labeled IoU/recall evaluation; provider response compatibility and accuracy require live validation.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if mode == .vision {
                    Text("Optional ground truth: [[x,y,width,height],…], normalized 0–1 from top left. Metrics match vehicle geometry at IoU ≥ 0.5, independently of fleet identity.").font(.caption)
                    TextEditor(text: $truth).frame(height: 70).border(.quaternary).accessibilityLabel("Vehicle benchmark ground truth")
                    Toggle("Every visible vehicle is annotated (enables precision)", isOn: $exhaustive)
                }
                Toggle("I confirm this content is public/licensed and approved for NVIDIA hosted processing", isOn: $approved).disabled(running)
                HStack {
                    Button(running ? "Processing…" : "Run hosted research", action: start).disabled(running || !approved)
                        .buttonStyle(.borderedProminent)
                    Button("Stop") { work?.cancel() }.disabled(!running)
                    Button("Export research result…", action: export).disabled(running || output.isEmpty)
                    if running { ProgressView().controlSize(.small) }
                }
                Text(status).font(.callout).textSelection(.enabled)
                ForEach(ranked) { result in
                    GroupBox {
                        VStack(alignment: .leading) {
                            Link("Original source · page \(result.passage.page)", destination: result.passage.sourceURL)
                            Text(result.passage.text).textSelection(.enabled)
                            Text("Relevance score: \(result.score.formatted()) · not a factual confidence").font(.caption)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if !output.isEmpty { Text(output).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }.padding()
        }
    }
    private func citation(text: String) throws -> PublicPassage {
        guard let url = URL(string: source) else { throw NIMError.invalidInput }
        return try PublicPassage(text: text, sourceURL: url, page: page)
    }
    private func addPassage() {
        do { passages.append(try citation(text: passage)); passage = ""; ranked = []; approved = false; status = "Passage added locally; no request sent" }
        catch { status = error.localizedDescription }
    }
    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .pdf]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard let size = values.fileSize, size <= 20_000_000 else { throw NIMError.oversized }
            let input: NSImage
            if url.pathExtension.lowercased() == "pdf" {
                guard let document = CGPDFDocument(url as CFURL), let pdfPage = document.page(at: page) else { throw NIMError.invalidInput }
                let bounds = pdfPage.getBoxRect(.mediaBox)
                guard bounds.width > 0, bounds.height > 0 else { throw NIMError.invalidInput }
                let scale = min(1400 / bounds.width, 1400 / bounds.height, 1)
                guard let context = CGContext(data: nil, width: max(1, Int(bounds.width * scale)), height: max(1, Int(bounds.height * scale)), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw NIMError.invalidInput }
                context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
                context.scaleBy(x: scale, y: scale); context.translateBy(x: -bounds.minX, y: -bounds.minY); context.drawPDFPage(pdfPage)
                guard let cg = context.makeImage() else { throw NIMError.invalidInput }
                input = NSImage(cgImage: cg, size: .zero)
            } else {
                guard let loaded = NSImage(contentsOf: url) else { throw NIMError.invalidInput }; input = loaded
            }
            guard input.size.width > 0, input.size.height > 0 else { throw NIMError.invalidInput }
            var prepared: Data?
            for maxSide in [1400.0, 1000, 700] {
                let scale = min(1, maxSide / max(input.size.width, input.size.height))
                let width = max(1, Int(input.size.width * scale)), height = max(1, Int(input.size.height * scale))
                guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
                NSColor.white.setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()
                input.draw(in: NSRect(x: 0, y: 0, width: width, height: height)); NSGraphicsContext.restoreGraphicsState()
                if let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.72]), data.count <= 175_000 { prepared = data; break }
            }
            guard let prepared, let preview = NSImage(data: prepared) else { throw NIMError.oversized }
            jpeg = prepared; image = preview; approved = false; output = ""; status = "Preview prepared locally; nothing sent"
        } catch { status = error.localizedDescription; jpeg = nil; image = nil }
    }
    private func start() {
        guard approved, !running else { return }
        // Capture the exact selected inputs; editing the form cannot change an in-flight request.
        let mode = mode, corpus = passages, query = query, jpeg = jpeg, truth = truth, exhaustive = exhaustive
        let selected: PublicPassage?
        do { selected = mode == .search ? nil : try citation(text: "Selected public page or fixture") }
        catch { status = error.localizedDescription; return }
        running = true; output = ""; ranked = []; status = "Sending selected public content to NVIDIA…"
        work = Task { @MainActor in
            defer { running = false; work = nil }
            do {
                let client = NIMCredentials.client()
                let start = ContinuousClock.now
                switch mode {
                case .search:
                    ranked = try await client.search(query: query, passages: corpus)
                    output = ranked.map { "\($0.passage.sourceURL.absoluteString) · page \($0.passage.page) · score \($0.score)\n\($0.passage.text)" }.joined(separator: "\n\n")
                case .document:
                    guard let jpeg, let selected else { throw NIMError.invalidInput }
                    let result = try await client.extractPublicPage(jpeg: jpeg, citation: selected)
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    output = "Research candidate · \(result.model)\nSource: \(result.sourceURL.absoluteString) · page \(result.page)\n\n\(result.text)\n\nStructured regions (data only):\n" + String(decoding: try encoder.encode(result.elements), as: UTF8.self)
                case .vision:
                    guard let jpeg, let selected else { throw NIMError.invalidInput }
                    let expected = truth.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : try ResearchBox.annotations(truth)
                    let result = try await client.detectPublicFixture(jpeg: jpeg)
                    let detections = try JSONDecoder().decode([ResearchDetection].self, from: result)
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let metrics = try expected.map { try VehicleResearchBenchmark.score(expected: $0, predictions: detections, exhaustive: exhaustive) }
                    let metricsText = try metrics.map { String(decoding: try encoder.encode($0), as: UTF8.self) } ?? "No ground truth supplied; accuracy not measured."
                    let hash = SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined()
                    guard let json = try? JSONSerialization.jsonObject(with: result), let formatted = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { throw NIMError.invalidResponse }
                    output = "Benchmark candidate · \(NIMClient.visionModel) · uncalibrated VLM boxes\nSource: \(selected.sourceURL.absoluteString) · page \(selected.page)\nInput SHA-256: \(hash)\nGeometry metrics:\n\(metricsText)\n\n" + String(decoding: formatted, as: UTF8.self)
                }
                try Task.checkCancellation()
                status = "Completed in \(start.duration(to: .now).formatted()) · inspect original sources; no records changed"
            } catch { status = Task.isCancelled ? "Stopped" : error.localizedDescription; output = ""; ranked = [] }
        }
    }
    private func export() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = "platewatch-nvidia-research.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try output.write(to: url, atomically: true, encoding: .utf8); status = "Research result exported" }
        catch { status = "Could not export result" }
    }
}
