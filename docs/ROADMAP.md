# ROADMAP.md

Legend: ✅ done · ◐ in progress · ⬜ planned

## M0 — Foundation (this bootstrap)
- ✅ Monorepo + package architecture (PlateKit, CaptureKit, VehicleML, PlateSync)
- ✅ Domain model + DTOs + plate normalization/patterns
- ✅ Vision-only baseline analyzer (works with no downloaded models)
- ✅ Model registry + conversion pipeline (`scripts/convert_models.py`)
- ✅ CloudKit sync backend + outbox; REST protocol client
- ✅ Reference Vapor server (read API + sightings ingest + stats + exports)
- ✅ iOS / macOS-Hub / watchOS app skeletons (xcodegen)
- ⬜ Record video of ≥ 99% plate detection on a test reel (needs model + tuning)

## M1 — Capture quality
- ⬜ Telephoto/exposure auto-tuning for moving traffic (1/500 s+ discipline) — hooks exist in CaptureKit (`minimumShutterSeconds`), tuning pass pending
- ⬜ Rolling-buffer "event clip" retention for fleet-classified events
- ✅ Hub: folder watch import (snapshot ingest from IP cameras via FTP)
- ✅ Geo bucketing: geohash-6 utility in PlateKit + CoreLocation provider in iOS app
- ✅ Multi-frame OCR fusion: `MultiFrameFusor` (spatial track IoU + independent-evidence voting) — 5 test cases
- ✅ Persistent on-device watchlists (SwiftData) + local alert evaluation
- ✅ Outbox drain loops wired in iOS app (timer + scene activation) and Hub
- ✅ Apple FoundationModels fleet-markings parser wired into the iOS capture path with heuristic fallback
- ⬜ Hub: Bonjour-advertised snapshot endpoint (filesystem watch shipped first)
- ⬜ Hub: RTSP ingest (VLCKit or AVF HLS interstitial)

## M2 — Identification depth
- ⬜ CoreML plate detector + plate OCR (converted models in registry)
- ⬜ Make/model/color classifier (CompCars-based)
- ⬜ Fleet markings parser: Vision text → FoundationModels `@Generable`
  extraction (agency name, unit #, "POLICE"/"FIRE" class text)
- ⬜ Plate-design classifier (state/exempt/federal plate families)
- ⬜ Vehicle Re-ID upgrade: OSNet CoreML model replacing feature prints
- ⬜ Damage/decal uniqueness cues folded into re-ID anchor

## M3 — Enrichment & records
- ⬜ Importers: GSA federal fleet, top-20 city fleet open-data sets
- ⬜ Auction-listing importer (GovDeals/PublicSurplus item pages → citations)
- ⬜ NHTSA vPIC VIN-decode connector
- ⬜ FOIA request generator (MuckRock-linked templates, prefilled agency/unit)
- ⬜ Moderator console (web, on the reference server)

## M4 — Network & UX
- ◐ CloudKit watchlist subscriptions → watchOS haptic alerts (subscription save implemented; push payload handling pending)
- ⬜ Heatmap + timeline views (agency-level, not individual-movement maps)
- ⬜ "Agency report card": fleet size, sightings density, budget links
- ◐ Public dataset exports: reference server ships /v1/export/sightings.csv + .geojson (bucketed); nightly scheduled job pending
- ⬜ CarPlay passive capture mode

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
