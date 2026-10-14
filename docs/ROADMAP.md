# ROADMAP.md

Legend: ✅ done · ◐ in progress · ⬜ planned

> **Status as of 2026-10-13:** the packages, server and importers are built and
> tested (129 tests), but the iOS app does not yet complete the core loop
> (camera → plate read → published sighting) and CloudKit is not live. See
> [QA-REPORT.md](QA-REPORT.md) for the ranked list of what is blocking, and
> **M-Alpha** below for the work that comes first.

## M-Alpha — Make it work end to end (current focus)
Sources: [QA-REPORT.md](QA-REPORT.md), [EVALUATION.md](EVALUATION.md).
- ✅ Camera frame orientation + overlay mapping; EXIF-correct photo import (P0-1)
- ✅ Graceful camera / permission / launch states; permission prompts asked in context (P1-1…P1-3)
- ✅ Fleet detection without CoreML models: door-text vehicles, graded markings score, Apple Vision classifier cue (P0-2, P0-4) — **57 % automatic recall at 100 % precision on real photos, 76 % with human confirmation**
- ✅ Human-in-the-loop "confirm this is a government vehicle" → moderation queue
- ✅ App icon, accent colour, launch screen, onboarding, About, branded empty states (P1-3…P1-5); painted amber/graphite icon added 2026-10-14 (IOS-UI-HANDOFF.md)
- ✅ Real map for Explore; aggregates work on CloudKit via client-side k-anonymity (P1-6)
- ✅ Evaluation corpus + harness (`eval/`), verified on a physical iPhone
- ✅ Crash fix: any recorded fleet detection crashed the app (CoreLocation delegate)
- ✅ Server build fixed; agency report HTML escaping fixed (QA F1, F2)
- ◐ CloudKit: backend restructured + `cloudkit/schema.ckdb` written; **needs the Apple-account step** (import schema, deploy to production) and a moderator publish tool (P0-5)
- ⏳ `models-v0.1.0` release drafted (not yet published; owner publishes): home-trained Create ML plate detector (head-to-head winner) + YOLOv8n fallback + vehicle/type/make-model/reid models; registry SHAs pinned; `.aar` packaging + `ModelArchive` extraction (P0-3). **Open:** `ModelManager` does not yet install `.aar` models; the `vehicle-make-model-classifier` asset is not yet packaged
- ⬜ Live-camera verification on a handheld device (mirroring cannot expose the camera) and a drive test
- ◐ iOS visual/review polish: detail + coarse-summary sharing, retry recovery, fleet watchlist validation/alert controls, local cleanup, semantic colors and painted icon landed (2026-10-14); full field/accessibility audit and received-history/media remain
- ✅ iOS simulator startup CloudKit trap fixed in app + delegate backend selection; regression test added

## M0 — Foundation (this bootstrap)
- ✅ Monorepo + package architecture (PlateKit, CaptureKit, VehicleML, PlateSync)
- ✅ Domain model + DTOs + plate normalization/patterns
- ✅ Vision-only baseline analyzer (works with no downloaded models)
- ✅ Model registry + conversion pipeline (`scripts/convert_models.py`)
- ✅ CloudKit sync backend + outbox; REST protocol client
- ✅ Reference Vapor server (read API + sightings ingest + stats + exports)
- ✅ iOS / macOS-Hub / watchOS app skeletons (xcodegen)
- ⬜ Record video of ≥ 99% plate detection on a test reel (blocked on QA P0-1…P0-4)

## M1 — Capture quality
- ⬜ Telephoto/exposure auto-tuning for moving traffic (1/500 s+ discipline) — hooks exist in CaptureKit (`minimumShutterSeconds`), tuning pass pending
- ⬜ Rolling-buffer "event clip" retention for fleet-classified events
- ✅ Hub: folder watch import (snapshot ingest from IP cameras via FTP)
- ✅ Geo bucketing: geohash-6 utility in PlateKit + CoreLocation provider in iOS app
- ✅ Multi-frame OCR fusion: `MultiFrameFusor` (spatial track IoU + independent-evidence voting) — 5 test cases
- ✅ Persistent on-device watchlists (SwiftData) + local alert evaluation
- ✅ Outbox drain loops wired in iOS app (timer + scene activation) and Hub
- ✅ Apple FoundationModels fleet-markings parser wired into the iOS capture path with heuristic fallback
- ✅ Hub: Bonjour-advertised snapshot endpoint (filesystem watch shipped first)
- ⬜ Hub: RTSP ingest (VLCKit or AVF HLS interstitial)

## M2 — Identification depth
- ◐ CoreML plate detector — ✅ home-trained Create ML detector shipped (registry 0.2.0, head-to-head winner); plate OCR still Vision baseline (TrOCR/plate-OCR conversion open)
- ⬜ Make/model/color classifier — colour model not yet found with a recordable licence (`docs/DECISIONS.md`)
- ◐ Fleet markings parser: Vision text → FoundationModels `@Generable` extraction (agency name, unit #, "POLICE"/"FIRE" class text) — wired into the iOS capture path
- ◐ Plate-design classifier (state/exempt/federal plate families) — decision: pivot from per-state (60 % accuracy, noisy keyword-search data) to the design families the redaction gate actually consumes (standard/exempt/government/official); train on plate crops (`docs/DECISIONS.md`)
- ⬜ Vehicle Re-ID upgrade: OSNet CoreML model replacing feature prints
- ⬜ Fleet gate classifier: binary fleet/civilian on detector crops (whole-scene 6-class training plateaued at 66–81 % due to background shortcut learning)

## M3 — Enrichment & records
- ✅ Importers: GSA federal fleet CSV → Vehicle + SourceCitation
- ✅ City fleet open-data feeds (top 20, configurable presets)
- ✅ NHTSA vPIC VIN decode connector
- ✅ Auction-listing importer (GovDeals/PublicSurplus item pages → citations)
- ✅ FOIA request generator (`FleetImporters/FOIARequestGenerator`: text-only drafts, prefilled agency/unit, placeholder requester — see `docs/FOIA.md`)
- ✅ Moderator console (server-rendered `GET /moderator` on the reference server; disabled unless `MODERATOR_TOKEN` is set)

## M4 — Network & UX
- ◐ CloudKit watchlist subscriptions → watchOS haptic alerts (subscription save implemented; push payload handling pending)
- ◐ Heatmap + timeline: k-anonymous aggregate API shipped (`GET /v1/aggregates/heatmap`, k=5, see `docs/DECISIONS.md`); map/timeline UI pending; agency scoping needs vehicle linking
- ◐ "Agency report card": server-rendered report page implemented (fleet size, 30-day sightings, budget link); no iOS surface yet
- ✅ Public dataset exports: reference server ships /v1/export/sightings.csv + .geojson (bucketed); nightly scheduled job (`NightlyExportJob` in server)
- ✅ Public feed is fleet-confirmed only (plates not persisted for unconfirmed sightings)
- ✅ iOS UI pass: plate-style badges, privacy chip, Open Settings, sync pills, app icon, launch screen, onboarding, About, branded empty states, Explore map (full redesign still open — see M-Alpha)
- ◐ CarPlay passive capture mode: scene delegate written; needs the Apple CarPlay entitlement and on-device verification (QA P1-8)

## M5 — Beyond Apple
- ⬜ REST mirror publicly deployed (Oracle Always Free)
- ⬜ Reference Python edge agent (Raspberry Pi HQ cam / OAK-4)
- ⬜ Android client via shared DTO spec + ONNX models
- ⬜ Web read-only explorer (Lite: exports; Full: mirror API)

## M6 — Remote camera sources & public feeds (macOS Hub)
Sources: [CAMERA-SOURCES.md](CAMERA-SOURCES.md). Every source feeds the same
`RedactionGate` — widening coverage must never widen what persists.
- ⬜ Continuity Camera (iPhone as webcam) + UVC webcam enumeration with a
  camera picker in the Hub (AVCaptureDevice `DiscoverySession`)
- ⬜ RTSP ingest rework — current `RTSPStreamHandler` uses `AVAssetReader` on
  an `rtsp://` URL (cannot open live streams) and calls a removed
  `RedactionGate` API (Hub does not compile); plan: HLS via
  `AVPlayerItemVideoOutput` first, VLCKit (LGPL) as fallback
- ⬜ Public traffic-cam feeds: `PublicFeedSource` + polite poller (HLS /
  snapshot JPEG; state 511 catalogs, USA first), citations per feed
- ⬜ Per-source recorded fixtures so CI never depends on live cameras

## M7 — Accountability records (people & vehicles cross-reference)
Sources: [ACCOUNTABILITY-DATA.md](ACCOUNTABILITY-DATA.md),
[LEGAL-ETHICS.md](LEGAL-ETHICS.md) Rule 6. **Ethics review required before
any collection code lands**; the `AccountabilityKit` type skeleton may land
first.
- ⬜ `AccountabilityKit` package: `OfficialProfile`, `IncidentRecord`,
  citation enforcement (no record without `SourceCitation`)
- ⬜ Roster/assignment importers extended to person-level records
- ⬜ Brady/decertification register + lawsuit docket importers (verbatim,
  cited, status-aware)
- ⬜ Cross-reference chain: sighting → unit → assignment → official → records
  (inference labeled, moderator-confirmed before publish)
- ⬜ Aggregation of existing public-interest publishers (cite-first, no
  re-hosting without attribution)
- ✅ FOIA request generator (`FleetImporters`, M3) — foundation for records
  requests that feed this program

## Ideas bin (brainstormed, not scheduled)
- ALPR-countermeasure documentation (where commercial ALPRs are, via EFF
  Atlas of Surveillance import) — "watch the watchers' watchers"
- Adversarial-frame awareness (detect plate obfuscation/evasion attempts by
  fleet vehicles — e.g. covered plates) as its own classifier
- Pattern-of-life anomaly alerts at **agency** granularity ("patrol presence
  up 3× around X event") — deliberately not person-level
- Public API for journalists w/ rate-limited query access
- Integration with court-record public data (vehicle appears in filings)
- Multi-language plates beyond Latin OCR (global expansion)
