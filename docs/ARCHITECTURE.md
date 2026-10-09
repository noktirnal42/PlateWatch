# ARCHITECTURE.md

## System overview

```
┌───────────────────────────── On-device (ANE / CPU) ─────────────────────────────┐
│                                                                                 │
│  AVCaptureSession ──▶ CaptureKit.FrameSource                                   │
│        │                     │                                                  │
│        ▼                     ▼                                                  │
│  RollingBuffer (HEVC)   AnalysisPipeline (VehicleML)                            │
│                              ├─ VehicleDetectionStage    (CoreML detector)      │
│                              ├─ PlateDetectionStage      (CoreML detector)      │
│                              ├─ PlateOCRStage            (Vision | CoreML OCR)  │
│                              ├─ VehicleAttributeStage    (classifier)           │
│                              ├─ FleetMarkingsStage       (Vision + FM parse)    │
│                              └─ ReIDStage                (feature print)        │
│                                    │                                            │
│                                    ▼                                            │
│                          DetectionFrame (PlateKit types)                        │
│                                    │                                            │
│                          RedactionGate  ◀── fleet-confidence threshold          │
└────────────────────────────────────┼───────────────────────────────────────────┘
                                     ▼
                              PlateSync (outbox)
                    ┌────────────────┴─────────────────┐
                    ▼                                  ▼
          CloudKit public DB                Reference REST server
          (default, free tier)              (Vapor; non-Apple platforms)
                    │                                  │
                    └──────────── community ───────────┘
                                  clients
```

## Layers

### 1. PlateKit — domain core (platform-pure Swift)
Types shared by every layer and mirrored on the wire:
`Plate`, `Vehicle`, `Agency`, `UnitAssignment`, `Sighting`, `SourceCitation`,
`Watchlist`, DTOs, plate normalization + regional pattern validation,
confidence model, redaction rules. **No dependencies beyond Foundation.**

### 2. CaptureKit — cameras in, frames out
- `PlateCaptureSession`: AVCaptureSession config that prefers plate-read
  geometry (resolution ≥1080p, telephoto selection, manual exposure hooks,
  fps throttling).
- Frame delivery as `FramePacket` (pixel buffer + timestamp + camera meta).
- Vision pre-stages run here only when they're cheap gating (motion/optical
  flow skip) — heavyweight ML belongs to VehicleML stages.
- Sources: live camera, photo library import, directory watcher (Mac hub
  snapshot ingest), test image sequences.

### 3. VehicleML — composable analysis
Every stage conforms to:

```swift
protocol AnalysisStage: Sendable {
    associatedtype Input: Sendable
    associatedtype Output: Sendable
    func process(_ input: Input, context: AnalysisContext) async throws -> Output
}
```

The pipeline is a linked list of stages so community members can register
custom stages (e.g. "aircraft N-number reader" at airports — same mission).

Model loading is **registry-driven**: `models/registry.json` (bundled copy +
updateable remote copy) maps a task to a `.mlpackage` URL + SHA-256.
`ModelManager` downloads, verifies, compiles, and hot-swaps models.

Baseline mode requires **zero downloads** (Vision-only), so the app is useful
on first launch and models can be fetched on Wi-Fi later.

### 4. PlateSync — the only network boundary
- `SyncBackend` protocol with two conformers:
  - `CloudKitBackend` (default): public DB, custom zone per shard,
    `CKQuerySubscription` for watchlist pushes, delta tokens for pull.
  - `RESTBackend`: the portable protocol client (also used by the eventual
    Android/web clients — the server is the platform boundary).
- **Outbox pattern**: detections persist (SwiftData) and upload retry-safe;
  user identity is the opaque CloudKit user record ID; no email collection.
- `RedactionGate` runs here (and server-side again) — unreviewed private
  plates never hit the network.

### 5. Apps
- **iOS** (`apps/ios`): handheld + dashcam capture, review queue, watchlist.
- **macOS Hub** (`apps/macos-hub`): fixed multi-source ingest — phone via
  Continuity Camera, IP-cam snapshot upload endpoint (Bonjour-advertised),
  folder watch; batch analysis; fleet fleet-local SQLite/Postgres optional.
- **watchOS** (`apps/watchos`): watchlist alerts, glanceable recent hits,
  dictated quick-log; no camera (hardware does not exist).

### 6. server/ — optional self-hosted mirror
Vapor + Postgres (+PostGIS). Purpose: cross-platform expansion and public
nightly data exports (CSV/GeoJSON dumps, torrent-seedable). Reads/writes the
same DTOs as `RESTBackend`. See docs/BACKEND.md for free hosting paths.

## Threading / concurrency model

- All stages are `Sendable`; pipeline execution on a dedicated
  `AnalysisExecutor` actor with backpressure (drop-oldest for live, queue-all
  for import).
- Swift 6 strict concurrency (`-strict-concurrency=complete`) everywhere.

## Extensibility points

- `AnalysisStage` (custom detectors/classifiers)
- `EnrichmentConnector` (new public-records sources)
- `SyncBackend` (new storage targets — e.g. a future on-prem deployment for
  a newsroom)
- Export plugins (GeoJSON, CSV, timeline PDF)
