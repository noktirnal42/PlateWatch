# ROADMAP.md

Legend: ✅ done · ◐ in progress · ⬜ planned

> **Status as of 2026-10-13:** the packages, server and importers are built and
> tested (129 tests), but the iOS app does not yet complete the core loop
> (camera → plate read → published sighting) and CloudKit publication is not complete. The production schema is deployed; client delivery and moderator publishing need verification. See
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
- ◐ CloudKit: backend restructured + `cloudkit/schema.ckdb` written; production schema deployment verified 2026-10-15; Hub client capability/diagnostics and operator-triggered reviewed delivery are wired, while two-account isolation and moderator publish tooling remain (P0-5)
- ✅ `models-v0.1.0` published (2026-10-14): home-trained Create ML plate detector (head-to-head winner) + YOLOv8n fallback + vehicle/type/make-model/reid models; registry SHAs pinned to the published assets; `.aar` packaging + isolated, symlink-rejecting `ModelArchive` extraction wired into `ModelManager` (P0-3)
- ⬜ Live-camera verification on a handheld device (mirroring cannot expose the camera) and a drive test
- ◐ iOS visual/review polish: detail + coarse-summary sharing, retry recovery, fleet watchlist validation/alert controls, local cleanup, semantic colors, painted icon and privacy-safe backend receipt history landed (2026-10-16); full field/accessibility audit, received media and event-clip export remain
- ✅ iOS simulator startup CloudKit trap fixed in app + delegate backend selection; regression test added

- ✅ Hub intact local evidence recovery by SHA-256 archive; all-vehicle body labels and explicit feed-filter reset (2026-10-15)

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
- ✅ Telephoto/exposure auto-tuning for moving traffic (1/500 s+ discipline) — CaptureKit selects the best available rear lens, caps auto-exposure duration, bounds ISO, disables HDR smearing, and reports live exposure; physical-device tuning remains QA
- ✅ Rolling-buffer "event clip" retention for fleet-classified events — bounded pre/post buffers and eviction-safe extraction are implemented; encoding/export remains a follow-up
- ✅ Hub: folder watch import (snapshot ingest from IP cameras via FTP)
- ✅ Geo bucketing: geohash-6 utility in PlateKit + CoreLocation provider in iOS app
- ✅ Multi-frame OCR fusion: `MultiFrameFusor` (spatial track IoU + independent-evidence voting) — 5 test cases
- ✅ Persistent on-device watchlists (SwiftData) + local alert evaluation
- ✅ Outbox drain loops wired in iOS app (timer + scene activation) and Hub
- ✅ Apple FoundationModels fleet-markings parser wired into the iOS capture path with heuristic fallback
- ✅ Hub: Bonjour-advertised snapshot endpoint (filesystem watch shipped first)
- ◐ Hub: HLS ingest is production-wired with policy relay, child-playlist handling, bounded cancellation and NV511 fixtures; raw RTSP still needs the separately licensed VLCKit/GStreamer path

## M2 — Identification depth
- ◐ CoreML plate detector — ✅ home-trained Create ML detector shipped (registry 0.2.0, head-to-head winner); plate OCR still Vision baseline (TrOCR/plate-OCR conversion open)
- ⬜ Make/model/color classifier — colour model not yet found with a recordable licence (`docs/DECISIONS.md`)
- ◐ Fleet markings parser: Vision text → FoundationModels `@Generable` extraction (agency name, unit #, "POLICE"/"FIRE" class text) — wired into the iOS capture path
- ◐ Plate-design classifier — conservative standard/exempt/government/official family mapping now lands in PlateKit and is gate-safe; trained plate-crop model and licensed family corpus remain open (`docs/DECISIONS.md`)
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
- ✅ CloudKit watchlist subscriptions → watchOS haptic alerts (subscription save, silent-push wake, delta matching and haptic/local alert handling implemented; entitlement and physical-device push QA remain)
- ◐ Heatmap + timeline: k-anonymous aggregate API, REST agency filter, and iOS map/timeline scope picker shipped (`GET /v1/aggregates/heatmap`, k=5, see `docs/DECISIONS.md`); agency scoping still needs deployed vehicle linking on CloudKit
- ◐ "Agency report card": server-rendered report page and iOS agency directory/detail surface implemented (fleet size, 30-day sightings, active units, budget link); CloudKit now has an explicit agencyKey join and aggregate query path, pending schema deployment/population
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
- ✅ Continuity/UVC camera enumeration and Live controls implemented; physical-device permission and analysis QA remains open.
- ⬜ RTSP ingest rework — compiles, but the existing AVAssetReader path is unsuitable for raw RTSP/live HLS.
  Wire reviewed HLS through AVPlayer playback/frame sampling first; VLCKit remains a separate licensed fallback.
- ✅ Public snapshot feeds: cited catalogues, terms/robots checks, shared polite pacing, source-specific jurisdiction/resolution rules.
- ✅ Favorites, reversible local blocks, and selected snapshot analysis overlays in Live.
- ✅ Offline help, native desktop toolbar/sidebar and primary glass action; UI/hardware coverage tracked in the [Hub handoff](HUB-HANDOFF-2026-10-14.md).
- ✅ Offline importer/poller/policy fixtures and hostless Hub regressions in CI.
- ◐ Continuous public-video playback and sampled analysis: real NV511 HLS and cancellation/restart fixtures verified 2026-10-15; full child-playlist/CDN/segment policy enforcement remains open. See [repair evidence](HUB-REPAIR-2026-10-15.md).

## M7 — Accountability records (people & vehicles cross-reference)
Sources: [ACCOUNTABILITY-DATA.md](ACCOUNTABILITY-DATA.md),
[LEGAL-ETHICS.md](LEGAL-ETHICS.md) Rule 6. **Ethics review required before
any collection code lands**; the `AccountabilityKit` type skeleton may land
first.
- ✅ `AccountabilityKit` package: `OfficialProfile`, `IncidentRecord`,
  citation enforcement (no record without `SourceCitation`)
- ⬜ Roster/assignment importers extended to person-level records
- 🟡 Brady/decertification register (CSV) + lawsuit docket (CourtListener, PACER with a dollar budget) importers — built,
  verbatim, cited, pending-until-accepted; live CourtListener/PACER endpoints not yet exercised
- 🟡 Cross-reference chain: unit → confirmed link → official → records, location-free, shown in Hub Review — built;
  operator-side People tab (cited profiles, hidden-until-confirmed unit links, explicit record attachment) built; second-person
  moderation and any publication path are not. Moderator audit entries carry a non-reversible reviewer fingerprint,
  and opt-in `REQUIRE_SECOND_REVIEW=1` now enforces distinct reviewers for approval.
- ✅ FOIA request tracker (Hub: Requests tab — due dates, appeal text, cited releases)
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

## Hub agent interfaces and internal agents

- [x] Local MCP tool interface for app-owned feed/records/review/navigation commands; client installer and portable skill.
- [x] In-app planner/executor driving the same validated commands, activity journal, budgets and stop control.
- [x] On-device Apple Foundation Models agent provider (separate from the existing markings parser).
- [x] Local MLX provider using the existing universal Hugging Face store, with missing-volume refusal and pinned/licensed models.
- [x] Optional NVIDIA hosted agent and public-research workspace (cited retrieval, document extraction, separate geometry benchmark); broader quality evaluation pending.
- [ ] Apple Foundation Models PCC provider: signed entitlement/account/platform and actual-inference validation; approved data boundary.
- [ ] Consider ACP frontend after a usable internal conversational agent exists.

Implementation and acceptance checks: [AGENT-INTEGRATION.md](AGENT-INTEGRATION.md).
