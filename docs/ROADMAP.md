# ROADMAP.md

Legend: ✅ done · ◐ in progress · ⬜ planned

> **Status as of 2026-10-13:** the packages, server and importers are built and
> tested (129 tests), but the iOS app does not yet complete the core loop
> (camera → plate read → published sighting) and CloudKit is not live. See
> [QA-REPORT.md](QA-REPORT.md) for the ranked list of what is blocking, and
> **M-Alpha** below for the work that comes first.

## M-Alpha — Make it work end to end (current focus)
Source: [QA-REPORT.md](QA-REPORT.md).
- ⬜ Camera frame orientation + overlay mapping (P0-1) — plates read in portrait/landscape
- ⬜ Graceful camera/permission/launch states; defer notification prompt (P1-1…P1-3)
- ⬜ Publish `models-v0.1.0` release; reconcile `models/registry.json` (P0-3)
- ⬜ Stand up CloudKit: schema export, Development→Production deploy, security roles (P0-5)
- ⬜ App icon, accent colour, launch screen, redesigned tabs (P1-4, P1-5)
- ⬜ Manual "record this vehicle" path + fleet classifier so sightings are possible without door text (P0-2, P0-4)
- ⬜ Real map for Explore wired to `/v1/aggregates/heatmap` (P1-6)
- ✅ Server build fixed; agency report HTML escaping fixed (QA F1, F2)

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
- ⬜ CoreML plate detector + plate OCR (converted models in registry)
- ⬜ Make/model/color classifier — colour model not yet found with a recordable licence (`docs/DECISIONS.md`)
- ⬜ Fleet markings parser: Vision text → FoundationModels `@Generable`
  extraction (agency name, unit #, "POLICE"/"FIRE" class text)
- ⬜ Plate-design classifier (state/exempt/federal plate families) — decision: build labeled dataset, licensing review first (`docs/DECISIONS.md`)
- ⬜ Vehicle Re-ID upgrade: OSNet CoreML model replacing feature prints
- ⬜ Damage/decal uniqueness cues folded into re-ID anchor

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
- ◐ iOS UI pass: plate-style badges, privacy chip, Open Settings and sync pills shipped; app icon, branding and tab redesign still open (QA P1-4/P1-5)
- ◐ CarPlay passive capture mode: scene delegate written; needs the Apple CarPlay entitlement and on-device verification (QA P1-8)

## M5 — Beyond Apple
- ⬜ REST mirror publicly deployed (Oracle Always Free)
- ⬜ Reference Python edge agent (Raspberry Pi HQ cam / OAK-4)
- ⬜ Android client via shared DTO spec + ONNX models
- ⬜ Web read-only explorer (Lite: exports; Full: mirror API)

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
