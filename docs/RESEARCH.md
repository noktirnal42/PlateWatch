# RESEARCH.md

Survey of existing open-source ALPR projects (and what we can port),
Apple-platform ML options, camera hardware, and built-in camera feasibility.
Last verified: October 2026.

---

## 1. Existing ALPR projects and what we take from each

### 1.1 openalpr/openalpr — the ancestor (AGPL-3.0)
- C++ library: OpenCV 2.4 + Tesseract 3.0.4. Detects plates via classical CV
  (cascades/edge analysis), OCRs via Tesseract with per-region char sets.
- Bindings: C#, Java, Node, Go, Python; historical iOS ports exist
  (`twelve17/openalpr-ios`, ObjC/OpenCV-era — powerful reference, not our
  runtime).
- **Take:** its `runtime_data/config` plate-pattern definitions per US state /
  country (ported into `PlateKit/PlatePatternCatalog`), its top-N candidate
  OCR output convention, and its JSON result shape as a compatibility target.
  AGPL — compatible with our license.
- **Don't take:** Tesseract/OpenCV pipeline (we replace with CoreML + Vision).

### 1.2 ankandrew/fast-plate-ocr + ankandrew/fast-alpr (actively maintained)
- Modern ONNX stack: YOLO-v9-t plate detector + a small CNN plate OCR
  (`global-plates-mobile-vit-v2`, etc.). Fast on CPU (single-digit ms).
- **Take:** this is our primary CoreML conversion source.
  `scripts/convert_models.py` converts the detector and OCR ONNX models to
  `.mlpackage` (INT8 palettized) for ANE.
- **License:** check per-model in `models/registry.json` — recorded at
  conversion time. fast-plate-ocr core is MIT; fast-alpr orchestration is not
  needed on-device (we re-implement in Swift).

### 1.3 sirius-ai/LPRNet_Pytorch (MIT)
- LPRNet: tiny end-to-end plate string recognizer with CTC — no per-character
  segmentation. Extremely small (sub-2MB), ideal on-device OCR fallback when a
  specialized plate model beats Vision's general OCR.
- **Take:** CoreML conversion candidate #2 for the OCR stage.

### 1.4 sergiomsilva/alpr-unconstrained (research, ECCVW 2018)
- WPOD-NET detector — plates at any angle/perspective with an unwarping
  homography. Useful future upgrade for off-axis roadside angles (mounted PoE
  cameras looking down a lane).

### 1.5 DoubangoTelecom/ultimateALPR-SDK (dual-license)
- Best-in-class ARM CPU performance (Raspberry Pi, Jetson). Not freely usable
  for our distribution, but useful as a **benchmark target**: >50fps on
  mobile-class ARM. Our ANE CoreML pipeline should exceed it.

### 1.6 faisalthaheem/open-lpr, roflcoopter/viseron, mehmetgoren/feniks
- open-lpr: web-service ALPR with REST patterns worth mirroring in our
  reference server.
- viseron/feniks: self-hosted NVR + AI pipelines — design reference for the
  **macOS Hub** app (watch RTSP/snapshot inputs, motion gating, event clips).

### 1.7 parkpow/deep-license-plate-recognition
- Platerecognizer's self-hostable engine. Commercial terms; use only as a
  correctness benchmark for our plate+region accuracy questions.

### 1.8 Vehicle re-identification (unplated tracking)
- Research lineage: VeRi-776 / VeRI-Wild datasets, OSNet/OSNet-AIN re-ID.
- **Our on-device MVP:** Apple Vision `VNGenerateImageFeaturePrintObservation`
  gives a perceptual feature print per vehicle crop with zero custom model —
  used for "same vehicle seen twice this week" clustering. A converted OSNet
  CoreML model is the upgrade path (registry: `vehicle-reid-osnet-x0_25`).

### 1.9 Civic analogues (data and governance inspiration)
- **EFF Atlas of Surveillance** — agency × surveillance-tech dataset; candidate
  import for the `Agency` universe and ALPR-countermeasures context.
- **MuckRock** — FOIA request patterns; our "Generate FOIA request" feature
  targets its templates (linking out, not scraping).
- **Open the Books / public salary databases** — already collected public
  records; cite-only integration (store citation URLs, we do not re-host).

---

## 2. Apple / CoreML technology survey

### 2.1 Works today with zero downloaded models
| Capability | API | Use |
|---|---|---|
| Plate OCR (baseline) | `VNRecognizeTextRequest` (accurate mode, Latin) | Read plate crop text |
| Plate region hypothesis | `VNDetectRectanglesRequest` + aspect ratio filter | Fallback plate localization |
| Vehicle/car detection (baseline) | `VNRecognizeObjectsRequest` needs a model; classic `VNDetectHumanRectanglesRequest` is not it — so baseline = full-frame plate search | — |
| Vehicle re-ID (baseline) | `VNGenerateImageFeaturePrintObservation` | Perceptual fingerprint, same-vehicle matching |
| Barcode/VIN stickers | `VNDetectBarcodesRequest` (PDF417/QR) | Fleet asset tags, VIN plates |

### 2.2 CoreML-converted open models (our main path — `models/registry.json`)
| Registry name | Task | Upstream |
|---|---|---|
| `plate-detector-yolov9t-384` | plate localization | fast-alpr ONNX |
| `plate-ocr-global-vit-v2` | plate text | fast-plate-ocr ONNX |
| `vehicle-detector-yolo11n` | vehicle boxes + class | Ultralytics (AGPL — fine, we're AGPL) |
| `vehicle-attr-mobilenetv3` | make/model/color | CompCars-trained checkpoint |
| `vehicle-reid-osnet-x0_25` | re-identification | OSNet (MIT) |

Conversion: `scripts/convert_models.py` (coremltools 9, INT8 palettization,
ANE-friendly input sizes, SHA-256 pinned in the registry).

### 2.3 Train-our-own, when needed
- **Create ML Object Detection / Classification** — transfer learning from
  community plate datasets (our labeled corpus grows from opt-in verified
  submissions of *fleet* plates).
- CoreML **model deployment via download**: compiled `.mlmodelc` fetched and
  verified at runtime (`ModelManager`); apps ship with baseline models
  compiled into the bundle; upgrades are OTA.

### 2.4 Foundation Models (iOS 26 / macOS 26+, on-device LLM)
- **Perfect fit for "door text → agency + unit number":** Vision returns raw
  scene text lines ("CITY OF AUSTIN", "POLICE", "UNIT 4421"). An on-device
  guided-generation pass (`@Generable struct FleetMarkings`) parses these into
  structured fields with confidences — no cloud, no API key.
- Guarded by `if #available(iOS 26.0, macOS 26.0, *)`; older devices fall back
  to the regex/heuristic parser in `PlateKit/SceneTextHeuristics`.

### 2.5 CloudKit (chosen free backend)
- **Public database** shared by all users of the app container — exactly the
  model a civic shared database needs.
- Free tier for developers; production quotas scale with user count and are
  generous for a structured-records workload (media thumbs as CKAssets are the
  main quota consumer — mitigated by storing hashes + small crops).
- **Push**: `CKQuerySubscription` = free watchlist alert delivery (watchOS
  complication updates included) — no push server to run.
- Public‑record enrichment jobs run client-side or as GitHub Actions
  scheduled importers, writing to a separate moderation zone.

### 2.6 Other Apple tech we use
- `CryptoKit` (ed25519 device keys, SHA-256 evidence hashes)
- `CoreLocation` region tagging at ~1 km precision for heatmaps (privacy
  bucket), exact coords stored only for fleet-confirmed sightings
- App Intents / Shortcuts ("Log sighting" action), WidgetKit watchlists
- watchOS 26: no camera hardware — companion roles only (alerts, quick log
  with dictation, watchlist glance). This is a hardware constraint, not laziness.

---

## 3. Camera hardware research (summary — full guide in HARDWARE.md)

**Verdicts:**
- **Best $0 option:** phone you already own (iPhone 12+). Daylight plate reads
  to ~12–15 m on the wide camera, ~25–30 m on the 5× telephoto (15 Pro Max / 16
  Pro class). Night performance is the weak point; external IR is impractical
  on phones — use burst + flash discipline, or accept daylight-only duty.
- **Best value fixed camera (~$120–250):** PoE bullet with 1/1.8" sensor,
  4 MP+, varifocal 2.7–13.5 mm, manual shutter ≥1/1000 s, 850 nm IR —
  Reolink RLC-811A / Amcrest IP4M-1046B class. Pair with a Mac mini running
  the Hub app for multi-cam 24/7 ingest (snapshot upload mode works with zero
  extra SDKs; RTSP ingest via VLCKit is roadmap).
- **DIY edge node (~$200):** Raspberry Pi 5 + HQ Camera + CS telephoto +
  850 nm illuminator; or Luxonis OAK-4 PoE with on-camera NN. These run the
  *reference Python edge agent* (future) or simply FTP snapshots to the Hub.
- **Dedicated ALPR (~$1,500+):** Axis Q1785-LE / Dahua ITC237 — only if a
  deployment needs certified capture of highway-speed plates at night.
- **Cluster/multi-angle hub:** any Apple-silicon Mac mini + PoE switch;
  Jetson Orin Nano only for non-Apple edge boxes.

---

## 4. Built-in camera feasibility (phones/tablets/laptops)

| Device | Verdict | Notes |
|---|---|---|
| iPhone 12 Pro → 16 Pro | ✅ Primary capture device | 30 fps Vision pipeline (plate detect + OCR every Nth frame), ProRes off, HEVC rolling buffer 30 s |
| iPad | ✅ Same pipeline | Bulky but excellent thermal headroom for long sessions |
| MacBook camera | ⚠️ Situational | 1080p fixed wide; fine for parking-lot duty at a desk, nothing else |
| Apple Watch | ❌ No camera exists | Companion app: watchlist alerts (haptic), dictated quick-log, Mark My Location |
| Continuity Camera (iPhone→Mac/Hub) | ✅ | Turns an iPhone into a wireless PoE-style node for a Mac Hub — legitimately useful |

Physical guidance: dash/windshield mount, telephoto preferred beyond 15 m,
lock AE/AF for motion, 1/500 s+ effective shutter at speed (use "action mode"
or manual exposure via AVCaptureDevice), angles ≤30° off plate normal.

---

## 5. Public-records enrichment sources (unit # → agency/officer)

Ranked by reliability — every enrichment writes a `SourceCitation`:

1. **Agency-published rosters/fleet lists** (city open-data portals, GSA
   federal fleet data, state fleet registries).
2. **FOIA releases** (MuckRock archives; agency compliance portals).
3. **Government auction listings** (GovDeals, PublicSurplus — routinely list
   unit numbers, VINs, mileage, decommission dates).
4. **Department social-media posts / press releases** (often name unit +
   officer for PR photos).
5. **NHTSA vPIC API** (free VIN decode — make/model/year verification; no PII).
6. **Community submissions** — lowest tier, require moderator verification.

Hard rule: nothing from DMV lookups (DPPA) or data brokers. See
LEGAL-ETHICS.md.

---

## 6. Prior art on "turning the tables"

- EFF's research into police ALPR networks (and the security failings of
  commercial ALPR clouds) validates the thesis that plate data accountability
  is a live policy issue.
- `GainSec/anti-crime-ecosystem-research` — independent audit of public-safety
  camera ecosystems; useful context for our security posture.
- We are unaware of any existing open-source *public-fleet-focused* ALPR
  database. This project occupies that gap.
