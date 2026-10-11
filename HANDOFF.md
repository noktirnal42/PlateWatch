# PlateWatch — Handoff Document

**Project:** PlateWatch — Open-source ALPR for government vehicle accountability
**Date:** 2026-10-11
**Branch:** `fix/sighting-unit-number` (10 commits ahead of origin)
**Status:** M2 substantially complete; M3–M5 pending; QA bug-sweep 2026-10-11 complete

---

## 0. Session Log — 2026-10-11 QA Sweep (protocol + stability bugs)

Six real bugs found and fixed by auditing the wire protocol and capture
pipeline; all packages + server build and all tests pass (65 tests).

1. **Server `VehicleObservationDTO` protocol break** (`server/Sources/App/DTO.swift`):
   server expected flat `hasLightBar/hasPushBar/hasFleetDecals` booleans while
   PlateKit nests them under `attributes: VehicleAttributes` — classifier
   output was silently dropped on every ingest. Server DTO now mirrors
   PlateKit's nested shape (`VehicleAttributesDTO`), with wire-decode tests.
2. **Delta-sync pagination broken** (`server/Sources/App/SightingsController.swift`):
   the client sends `?cursor=…` but the server only read `since` — every pull
   returned page 1 forever. Additionally, a second-precision `nextCursor`
   plus a strict `>` filter skipped rows sharing the boundary timestamp.
   Fixed: compound cursor `"<ISO-8601-with-fractional-seconds>|<last-UUID>"`,
   sort `(capturedAt DESC, id DESC)`, OR-group filter `(capturedAt < t) OR
   (capturedAt == t AND id < lastID)`; legacy bare-date cursors still
   accepted. Contract documented in `docs/BACKEND.md`.
3. **Replay receipts lied about `serverReceivedAt`** — the idempotent-replay
   path returned `capturedAt`. `Sighting` now carries a `created_at`
   timestamp (`AddSightingCreatedAt` migration registered in `configure`).
4. **Outbox idempotency keys were per-process** (`PlateSync/Outbox.swift`):
   `Hasher` is seeded per launch, so a drained outbox after an app restart
   produced NEW keys — the server's idempotency dedupe never fired and
   duplicates were stored. Replaced with a deterministic SHA-256 digest over
   a canonical byte serialization; golden-value test pins the algorithm.
5. **CloudKit cursor never round-tripped** (`PlateSync/CloudKitBackend.swift`):
   next-cursor was stored via `String(describing:)` (unarchivable) and the
   decoded cursor was never passed to the query — every pull re-queried from
   the top. Now keyed-archived base64 tokens + `records(continuingMatchFrom:)`.
   Replay receipts also derive a stable `sightingID` from the record name
   (was `UUID()` on the already-exists path).
6. **Rolling-buffer crash on wrap** (`CaptureKit`): `FrameRollingBuffer
   .extractClip` used array positions while `PlateCaptureSession
   .extractEventClip` passes absolute frame counters — after the buffer
   wrapped, extraction formed an invalid Array range (`frames[940...134]`)
   and would crash on the first fleet event. `extractClip` now filters by
   `sequenceNumber`, evicted/inverted windows return `[]`, and the trigger
   frame is located by sequence number (anchored to the nearest retained
   frame if evicted). Regression tests added.
   Also: `RTSPFrameSource` no longer injects a synthetic black 1080p frame
   (with a force-unwrapped CVPixelBuffer) into the pipeline on stream error.

All 50 pre-existing tests still pass; new tests bring the count to 65
(PlateKit 22, CaptureKit 12, VehicleML 7, PlateSync 9, FMP 3, server 13).

---

## 1. Executive Summary

PlateWatch is a Swift-first, on-device ALPR system focused on **taxpayer-funded vehicle accountability** (police, fire, EMS, public works, transit, federal fleets). It is **not** a general people-tracking system. All code respects the legal/ethical guardrails in `docs/LEGAL-ETHICS.md`: fleet-only ingestion, public-records-only enrichment, provenance everywhere, on-device first, no secrets in repo.

**Architecture:** Monorepo with 5 Swift packages + 1 FoundationModels parser + Vapor reference server + 3 app targets (iOS, macOS-Hub, watchOS).

| Package | Role | Tests |
|---------|------|-------|
| `PlateKit` | Domain models, DTOs, plate normalization, redaction gate, geohash, patterns | 22 |
| `CaptureKit` | Camera session config, adaptive exposure, rolling event clips, RTSP/HLS source | 11 |
| `VehicleML` | Analysis pipeline, multi-frame fusion, model registry, CoreML detector stages | 7 |
| `PlateSync` | CloudKit/REST sync backend, outbox, watchlists, device identity | 7 |
| `FoundationModelsParser` | `@Generable` fleet markings parser (Apple Intelligence, iOS 26+/macOS 26+) | 3 |
| **Server** | Vapor reference server (ingest, delta sync, exports, stats) | — |

**All 50 tests pass** across 5 packages.

---

## 2. What Works (M0–M2 Complete)

### M0 — Foundation
- Monorepo + package architecture (PlateKit ← CaptureKit/VehicleML ← PlateSync)
- Domain models + DTOs + plate normalization/patterns (US states, US Gov, exempt)
- Vision-only baseline analyzer (works with zero downloaded models)
- Model registry + conversion pipeline (`scripts/convert_models.py`)
- CloudKit sync backend + outbox; REST protocol client
- Vapor reference server (ingest, delta sync, stats, CSV/GeoJSON exports)
- iOS / macOS-Hub / watchOS app skeletons (xcodegen)

### M1 — Capture Quality
- **Telephoto/exposure auto-tuning**: `AdaptiveExposureController` maintains 1/500s+ shutter while bounding ISO (800 handheld, 1600 dashcam). Updates every 10 frames from actual exposure metadata.
- **Rolling event clips**: `FrameRollingBuffer` retains configurable pre/post-roll (2s/1s handheld, 3s/2s dashcam). `onFleetEvent` callback + `extractEventClip()` for triggered extraction.
- **Multi-frame OCR fusion**: `MultiFrameFusor` (spatial track IoU + independent-evidence voting) — 5 test cases passing.
- **Persistent watchlists**: SwiftData local cache + local alert evaluation.
- **Outbox drain loops**: Timer + scene activation in iOS app and Hub.
- **Apple FoundationModels fleet-markings parser** wired into iOS capture path with heuristic fallback.
- **Hub**: Folder-watch import (IP camera FTP snapshots) — zero SDKs, no cloud.
- **Geo bucketing**: geohash-6 utility + CoreLocation provider.
- **Hub Bonjour HTTP endpoint**: `POST /snapshot` with raw JPEG/PNG → pipeline → outbox. Advertises `_platewatch-snapshot._tcp`.

### M2 — Identification Depth
- **CoreML model conversion pipeline**: `scripts/convert_models.py` downloads from HF, converts via coremltools/ultralytics, INT8 palettized, registry updated with SHA256.
- **Models converted & registered** (all INT8 palettized, ANE-friendly):
  - `plate-detector-yolov8n` — 3.1 MB (joker5914/yolov8n-license-plate)
  - `vehicle-detector-yolov8n` — 3.2 MB (Ultralytics YOLOv8n COCO)
  - `vehicle-type-classifier` — 86 MB ViT-B/16 10-class (dima806/vehicle_10_types_image_detection)
  - `vehicle-make-model-classifier` — ViT-B/16 30+ models (dima806/car_models_image_detection)
- **Model registry entries** (8 total) with SHA256, source URLs, licenses, input descriptions.
- **Fleet markings parser**: `FoundationModelsParser` using `@Generable` + `LanguageModelSession` (iOS 26+/macOS 26+). Falls back to `SceneTextHeuristics` on older OS. Extracts: agencyName, unitNumber, serviceClass, ownershipLine, confidence.
- **Vehicle Re-ID source**: OSNet x0.25 ONNX (anriha/osnet_x0_25_msmt17, MSMT17-trained) — conversion blocked by coremltools 9.x dropping ONNX support. Feature-print re-ID active as fallback.
- **Plate-design classifier**: Placeholder entry (custom training required — no pre-trained US plate design model on HF).

---

## 3. Current Blockers / Known Issues

| Area | Blocker | Workaround / Status |
|------|---------|---------------------|
| **OSNet Vehicle Re-ID** | coremltools 9.x dropped ONNX `source` support; `onnx2torch` fails on BatchNorm spatial rank | Feature-print re-ID (Vision) active. Need PyTorch export path or coremltools fix. |
| **Color Classifier** | MobileViT v2 model (EstherSan/car_identified_model_7) missing `image_processor_type` in preprocessor_config.json | Placeholder entry in registry. Need model with proper preprocessor or custom training. |
| **Plate-design Classifier** | No pre-trained US plate design classifier on HF (state/exempt/federal families) | Placeholder entry. Requires custom dataset + training. |
| **Plate OCR (TrOCR)** | Transformers vision-encoder-decoder export path not implemented in converter | Vision baseline OCR active. Need `transformers` → CoreML path for TrOCR. |
| **YOLO11n Export** | Broken in coremltools 9.x (int op conversion failure) | Using YOLOv8n instead (stable). |
| **Palettization API** | coremltools 9.x changed `nbits` → `quantize` API | Fixed in converter (`palettize_weights` without nbits). |
| **FoundationModels Availability** | Requires iOS 26+/macOS 26+ with Apple Intelligence | Heuristic fallback works everywhere. |

---

## 4. Architecture Details

### Package Dependency Graph
```
PlateKit (domain, DTOs, redaction, geohash)
  ↑
CaptureKit (camera, exposure, frames, RTSP)
  ↑
VehicleML (pipeline, fusion, detectors, registry)
  ↑
PlateSync (CloudKit/REST, outbox, watchlists)
  ↑
Apps: iOS, macOS-Hub, watchOS
```

### Key Data Flow
1. **Capture** → `PlateCaptureSession` (adaptive exposure) or `FileFrameSource`/`RTSPFrameSource`
2. **Analyze** → `PlateAnalysisPipeline` (Vision baseline + CoreML detectors when available)
3. **Fuse** → `MultiFrameFusor` (track IoU + voting across frames)
4. **Gate** → `RedactionGate` (fleet confidence threshold; private plates dropped)
5. **Parse** → `FoundationModelsParser` (Apple Intelligence) or `SceneTextHeuristics` (heuristic)
6. **Sync** → `PlateSync` outbox → `CloudKitBackend` (entitled) or `RESTBackend` (dev)
6. **Server** → Vapor ingest → Postgres → delta sync / exports

### Sync Protocol (DTOs)
Defined in `PlateKit/Sources/PlateKit/DTO/SyncDTOs.swift` — **must stay field-compatible** with `server/Sources/App/DTO.swift`.
- `SightingSubmissionDTO` (ingest)
- `PublicSightingDTO` / `SightingPageDTO` (delta pull)
- `PublicVehicleDTO` (plate lookup)
- `PublicAgencyDTO` (agency lookup)

### Redaction Gate (Legal Compliance)
`RedactionGate` enforces fleet-only ingestion:
- `verdict(fleetConfidence)` → `.persistAndSync` | `.dropExactGeo` | `.reject`
- Thresholds: fleet classifier + markings + known unit + exempt plate design
- Private plates → dropped before upload; exact geo withheld until fleet-confirmed

---

## 5. How to Build & Test

```bash
# All packages
swift build --package-path packages/PlateKit
swift build --package-path packages/CaptureKit
swift build --package-path packages/VehicleML
swift build --package-path packages/PlateSync
swift build --package-path packages/FoundationModelsParser
swift build --package-path server

# All tests
swift test --package-path packages/PlateKit
swift test --package-path packages/CaptureKit
swift test --package-path packages/VehicleML
swift test --package-path packages/PlateSync
swift test --package-path packages/FoundationModelsParser

# macOS Hub (Xcode project)
xcodebuild -project apps/macos-hub/PlateWatchHub.xcodeproj -scheme PlateWatchHub build
```

### Model Conversion
```bash
cd scripts
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python convert_models.py --all
# or specific task:
.venv/bin/python convert_models.py --task vehicle-reid
```

**Requirements:** Python 3.12+, coremltools 9.x, ultralytics, transformers, onnx, huggingface_hub.

---

## 6. Remaining Work (M2–M5)

### M2 — Finish Identification Depth
- [ ] **Color Classifier**: Fix MobileViT v2 image processor or find compatible model
- [ ] **Plate-design Classifier**: Custom training on US plate design dataset (state/exempt/federal)
- [ ] **OSNet Re-ID**: Resolve coremltools ONNX conversion (PyTorch export → coremltools, or wait for ONNX support)
- [ ] **Plate OCR (TrOCR)**: Implement transformers vision-encoder-decoder → CoreML path
- [ ] **Damage/Decal Uniqueness**: Fold into re-ID anchor for vehicle fingerprinting

### M3 — Enrichment & Records
- [ ] **GSA Federal Fleet Importer**: Parse GSA CSV/API → `Vehicle` + `SourceCitation`
- [ ] **City Fleet Importers**: Top 20 open-data city fleet feeds
- [ ] **Auction Listing Importer**: GovDeals/PublicSurplus scraping → citations
- [ ] **NHTSA vPIC VIN Decode**: Connector for VIN → make/model/year
- [ ] **FOIA Request Generator**: MuckRock-linked templates, prefilled agency/unit
- [ ] **Moderator Console**: Web UI on reference server (approve/hold/reject sightings)

### M4 — Network & UX
- [ ] **CloudKit Push → watchOS Haptics**: Subscription payload handling (save implemented)
- [ ] **Heatmap + Timeline Views**: Agency-level (not individual movement)
- [ ] **Agency Report Card**: Fleet size, sightings density, budget links
- [ ] **Nightly Export Job**: Scheduled CSV/GeoJSON export on server
- [ ] **CarPlay Passive Capture**: Background capture mode

### M5 — Beyond Apple
- [ ] **REST Mirror Deployment**: Oracle Always Free / Fly.io
- [ ] **Python Edge Agent**: Raspberry Pi HQ Cam / OAK-4
- [ ] **Android Client**: Shared DTO spec + ONNX models
- [ ] **Web Explorer**: Read-only (Lite: static exports; Full: mirror API)

---

## 7. Legal / Ethical Guardrails (Non-Negotiable)

From `docs/LEGAL-ETHICS.md` — encoded in code:
1. **Fleet-only ingestion**: Private plates dropped by `RedactionGate` unless fleet-confirmed
2. **Provenance everywhere**: Every enriched field requires `SourceCitation` (URL + retrieval date + source type)
3. **On-device first**: No telemetry, analytics, frame uploads, third-party trackers
4. **Public records only for enrichment**: Agency rosters, fleet registries, FOIA, auction listings — **never** DMV/broker data
5. **Safety hold**: Domestic violence, victim services, undercover units excluded from real-time alerts
6. **Anti-abuse**: No doxxing, no home addresses, no family info; rate-limited by CloudKit identity

---

## 8. Key Files for Onboarding

| File | Purpose |
|------|---------|
| `AGENTS.md` | AI agent guardrails & conventions |
| `docs/LEGAL-ETHICS.md` | Legal/ethical rules (encoded in `RedactionGate`, `SourceCitation`) |
| `docs/DATA-MODEL.md` | Canonical schema (Vehicle, Plate, Agency, Sighting, SourceCitation) |
| `docs/ROADMAP.md` | Milestone checkboxes (source of truth for progress) |
| `PlateKit/Sources/PlateKit/Redaction/RedactionGate.swift` | Fleet-only enforcement logic |
| `PlateKit/Sources/PlateKit/DTO/SyncDTOs.swift` | Cross-platform protocol (matches server DTOs) |
| `VehicleML/Sources/VehicleML/ModelRegistry.swift` | CoreML model loading by registry name |
| `CaptureKit/Sources/CaptureKit/PlateCaptureSession.swift` | Adaptive exposure + rolling clips |
| `PlateSync/Sources/PlateSync/SyncBackends.swift` | Auto CloudKit/REST selection |
| `FoundationModelsParser/Sources/FoundationModelsParser/FleetMarkingsParser.swift` | `@Generable` parser + fallback |
| `server/Sources/App/SightingsController.swift` | Ingest + delta sync endpoints |
| `scripts/convert_models.py` | Model conversion pipeline |

---

## 8. Immediate Next Steps (If Continuing)

1. **Resolve OSNet conversion**: Try PyTorch export of OSNet → coremltools, or wait for ONNX support in coremltools 10.x
2. **Color classifier**: Find MobileViT model with proper `image_processor_type` or train custom
3. **Plate OCR**: Implement TrOCR export via `torch.export` + coremltools
4. **M3 importers**: Start with GSA federal fleet CSV → `Vehicle` + `SourceCitation` pipeline
5. **Server exports**: Add nightly cron job for CSV/GeoJSON export

---

## 9. Git History (Key Commits)

```
5d52990 M2: OSNet re-ID source identified + plate-design classifier placeholder
a341f37 M2: ViT car model classifier + color classifier entries
e2d6ef4 M2: Transformers image classification pipeline + vehicle type classifier
8a5613e M2: CoreML model conversion pipeline + YOLOv8 vehicle/plate detectors
6be522c CaptureKit: RTSP/HLS frame source (M1)
44d67ce FoundationModelsParser: @Generable fleet markings parser (M2)
1b62154 CaptureKit: adaptive exposure tuning + rolling event clip buffer
3d86cd8 SyncBackends: auto-select CloudKit vs REST by entitlement
0f46b89 SyncBackends: auto-select CloudKit vs REST by entitlement
cd0584d Fix: persist unitNumber on sightings (QA catch)
```

---

## 10. Contact / Resources

- **Repo**: This monorepo (Swift 6.4, Xcode 27, macOS 27 SDK)
- **Model Releases**: GitHub Releases `models-vX.Y.Z` (weights never committed)
- **Legal**: `docs/LEGAL-ETHICS.md` — read before contributing
- **CI**: `.github/workflows/ci.yml` (source of truth for build matrix)

---

**End of Handoff.** This document reflects state as of commit `5d52990` (2026-10-11). All 50 tests pass. The codebase is ready for M3 work or M2 completion.