# PROJECTS.md — workstreams: PlateWatch as small linked projects

PlateWatch is one monorepo but development is organized as **workstreams** —
small, independently trackable projects with explicit links. Each workstream
owns packages/paths, has its own docs, test command, status, and next tasks.
A contributor or agent session should load `AGENTS.md` + **one** workstream
section (plus the docs it links) and keep its diffs inside that workstream.

Why: the codebase grew faster than its structure. Shared code drifted (the
Hub's capture path broke the moment `RedactionGate.fleetConfidence` evolved —
each app had its own copy of the scoring call), and no single view answered
"what is done vs planned vs working". This file is that view; keep the
**Status** lines honest at the end of every session (they are the machine- and
human-readable dashboard).

Cross-workstream law (unchanged from AGENTS.md):
`PlateKit ← CaptureKit/VehicleML ← PlateSync` — and now
`PlateKit ← AccountabilityKit` and `PlateKit ← FeedIngest`. No cycles.
Apps depend on packages; packages never depend on apps. Every workstream's
tests must stay green before its status advances.

---

## WS1 — Capture (iOS · watchOS · CarPlay)

- **Owns:** `packages/CaptureKit`, `apps/ios`, `apps/watchos`, live camera
  path, review flow, on-device self-test.
- **Docs:** NEXT-STEPS §2 (field test), QA-REPORT, EVALUATION.
- **Test:** `swift test --package-path packages/CaptureKit` + iOS build.
- **Status:** still-photo core loop inherited; 2026-10-16 iOS mobile extension pass adds published-fleet sightings, backend connection diagnostics, all-vehicle class overlays, and reliable large-text watchlist focus; 2026-10-14 iOS review/branding pass
  adds observation detail/export, retry recovery, validated fleet watchlists,
  local cleanup and simulator CloudKit startup-crash fix. See
  [IOS-UI-HANDOFF.md](IOS-UI-HANDOFF.md) for validation and screenshot boundaries.
  CaptureKit now selects the best available rear lens, applies bounded auto-exposure/ISO tuning,
  records exposure diagnostics, and retains eviction-safe pre/post event clips; physical-device
  tuning and clip export remain QA/follow-up gates.
  Handheld live-camera field testing remains pending. The simulator now proves the REST health path and
  renders the published-fleet feed (empty state is explicit when the backend has no published records);
  signed CloudKit account/database verification remains external. CloudKit watchlist subscription registration,
  watchOS silent-push delta matching, haptics and local alert presentation are implemented; signed
  entitlement and physical-device push delivery remain external QA gates.
  The phone now mirrors its normalized local watchlist to the companion watch
  through WatchConnectivity; pairing and push delivery remain physical-device gates.
- **Next:** handheld iPhone test (portrait+landscape, dusk, motion/thermal), spoken
  VoiceOver audit, received-history/remote withdrawal, physical watch alerts;
  CarPlay entitlement gate.

## WS2 — Hub & remote camera sources (macOS)

- **Owns:** `apps/macos-hub`, new `packages/FeedIngest`, all non-handheld
  frame sources (folder watch, Bonjour snapshots, Continuity Camera, UVC
  webcams, RTSP rework, public traffic cams).
- **Docs:** [CAMERA-SOURCES.md](CAMERA-SOURCES.md) (status matrix per source).
- **Test:** `swift test --package-path packages/FeedIngest` + Hub scheme tests (see handoff).
- **CSV import:** standard header mapping, agency and citation URL fields added; [export/source research](research/BRADY-CSV-EXPORTS-2026-10-14.md) records verified conversions and next sources.
- **QA follow-up:** see [HUB-QA-2026-10-14.md](HUB-QA-2026-10-14.md) for post-Claude/GLM render fixes, source links and outstanding visual checks.
- **Status:** 2026-10-15 Hub repair builds, tests and signed local installation verified; see
  [repair evidence](HUB-REPAIR-2026-10-15.md). Nevada's keyed catalogue now preserves snapshots and HLS
  per view. Real NV511 HLS playback/analysis and all ten existing favorite previews verified.
  HLS decodes on demand for the selected Live camera; ordinary previews use the bounded live decoder.
  Review multi-rejection/enlargement and pane persistence repaired; original eight queued records
  preserved (their payloads lacked image bytes before this repair). Snapshot failures, policy failures
  and manual recovery are distinct. OpenCode watch controls reconciled: persisted selective polling,
  four-stream HLS budget and Live priority; watch scan hang fixed and native toggling verified.
  Local Review preserves intact evidence crops: overlapping vehicles and foreign text no longer
  remove or black out photos (owner clarification, 2026-10-15; 37 Hub tests, four opt-in skips).
  Child-resource/redirect policy relay and bounded preview slots implemented and native NV511 playback verified;
  163 FeedIngest and 45 Hub tests pass (four Hub opt-in skips). HLS watch slots rotate every minute
  with Live pinned; explicit filter reset/reload restores the complete visible catalogue.
  The feed browser now has a persisted-safe Reset view action that also returns from Favorites/Blocked scope
  to the complete catalogue, preventing cameras from appearing lost after relaunch.
  HLS Live now bounds a selected decoder attempt to 15 seconds and exposes a Retry action that tears down
  the stale player before restarting it; this makes provider segment failures visible and recoverable.
  NV511 refreshes now merge the current keyed catalogue, and a retired HLS route can fall back to its paired
  approved snapshot view in Live with an explicit status, preserving a usable camera while the provider repairs video.
  Local evidence has hash-addressed recovery copies, and Live shows generic vehicle classes (including
  readable SUV/van/pickup/sedan/motorbike aliases and classifier confidence when a body label is unavailable).
  iOS now exposes the public agency directory and REST-backed report-card detail flow through the shared
  sync boundary; CloudKit directory records are supported, while aggregate report delivery remains a
  deployment/mirror gate until the required public records are present.
  CloudKit-entitled Hub delivery retains local acknowledgement receipts and
  identifies CloudKit versus the separate REST moderation queue. Review can
  recover creator-owned history and explicitly hand it through the REST privacy
  gate into the Moderation queue; automatic mirroring and server-side CloudKit
  publication remain deployment/account gates.
  The Hub now has an opt-in ephemeral presence lease that reports live processor
  totals and per-feed demand through the REST boundary; leases expire after 90
  seconds and are never persisted. iOS/watch clients and hosted deployment
  remain follow-up gates. The iOS capture path now contributes an opt-in
  ephemeral active-processing lease, and the watch companion contributes an
  in-use lease while foregrounded; both use the same non-persistent REST
  presence boundary as Hub.
  Sustained pilot, unsupported playlist forms and physical QA remain.
- **Visual polish:** screenshot-checked Dashboard, feed browser and Sandy Live view; native-symbol metrics, dashboard shortcuts, camera/host rows and optional readable overlays. Actual Dashboard capture added to Pages source. Minimum-width feed status clipping fixed; console-only System/Light/Dark controls and ⌘1–⌘8 navigation added. Actual menu/key/overlay-checkbox interactions verified; System appearance and original window size restored.
- **Court-search results:** each CourtListener/PACER search replaces the Current search view immediately; empty/error responses remain empty and late older responses are ignored. Saved pending and accepted records stay available in separate tabs. Regression coverage includes repeat-search deduplication and stale completions.
- **Agent interface:** authenticated app-owned commands + local MCP/skill; [integration and internal-agent plan](AGENT-INTEGRATION.md). Local MLX and on-device Foundation Models now complete bounded tasks in the signed Hub; seven agent-core tests and 45 Hub tests pass (four Hub opt-in skips). Stop/journal verified. Owner-selected NVIDIA hosted agent/retrieval/extraction/vehicle-benchmark integration is implemented; live endpoint corrections and limits are recorded in the NIM research report. PCC remains pending.
- **Next:** extend the mediated real-camera proof into
  a sustained quality/freshness/CPU pilot and broader internal-agent task/attribution evaluation
  in AGENT-INTEGRATION.md. Credentialed source expansion and physical hardware/permission QA remain.
  Current continuation evidence and remaining gates: [repair report](HUB-REPAIR-2026-10-15.md).
  2026-10-16 physical QA: signed iOS build installed and launched on iPhone 16 Pro Max;
  portrait and landscape screenshots show the capture UI and all-vehicle class overlays.
  Signed watch companion installed and launched on Apple Watch Series 9; the recent-hits
  and Quick log surface rendered successfully. The watch now includes notification
  permission, visible unread-hit state, and a WidgetKit complication with fleet-hit and
  opt-in active-user counts. Camera permission/real-scene capture and CloudKit push
  delivery still require an operator field exercise; the latest watch install was blocked
  when the USB watch connection dropped and should be retried after reconnecting it.

## WS3 — Recognition & evaluation

- **Owns:** `packages/VehicleML`, `eval/`, `models/`, model registry,
  conversion scripts.
- **Docs:** EVALUATION, NEXT-STEPS §3–5, PLATE-DESIGN-DATASET, DECISIONS.
- **Test:** `swift test --package-path packages/VehicleML` +
  `EvalHarness eval [--models models/cache]`.
- **Status:** baseline 59 % auto recall / 100 % precision (62-image corpus);
  official-plate reading landed; CoreML plate detector lifts plate reads
  10→15/62 images; vehicle-detector fusion fixed to not erase text-inferred
  fleet class. 2026-10-15: bounded detail detection recovers the owner-reported Arlington
  SUV in a local screenshot holdout; 31 VehicleML tests pass with that opt-in enabled.
  Semantic label filtering now excludes non-vehicle COCO objects; a labeled camera benchmark separately
  scores geometry and fleet coverage (36 tests pass). The local SUV box is recovered but its fleet
  identity remains unconfirmed. Generic car/truck/bus/motorcycle labels are now retained separately
  as body-type attributes for all Live detections, without promoting fleet status (37 VehicleML
  tests, one local-image opt-in skip). See EVALUATION.md; OCR and broader fleet recall remain open.
- **Next:** grow the ground-truth `plate` corpus (USA, licensed, challenging
  low-contrast examples); improve the Vision baseline with a trained OCR model,
  make/model/color classifier (Create ML GUI path); fleet-specific
  classifier for recall.

## WS4 — Records & accountability

- **Owns:** `packages/FleetImporters`, new `packages/AccountabilityKit`,
  FOIA/public-records tooling, person-records program (M7).
- **Docs:** [ACCOUNTABILITY-DATA.md](ACCOUNTABILITY-DATA.md), FOIA,
  LEGAL-ETHICS (Rules 2/6), DATA-MODEL (planned entities).
- **Test:** `swift test --package-path packages/FleetImporters` +
  `swift test --package-path packages/AccountabilityKit`.
- **Status:** GSA/city-fleet/auction importers + FOIA generator shipped; 2026-10-15 FOIA tracker, CSV list and
  CourtListener/PACER (budget-guarded) importers, record candidates and the location-free unit-records index landed
  (local only, `docs/ACCOUNTABILITY-DATA.md`). People tab (operator-side cited links) built. Roster CSV importer and an eight-source one-click police roster catalogue built. Not built: second-person moderation, any publication.
- **Next:** exercise CourtListener/PACER live (owner testing, free allowance); read statute text for the FOIA
  deadline table (VA unconfirmed, CA AB 1821 pending).

## WS5 — Sync & backend

- **Owns:** `packages/PlateSync`, `server/`, `cloudkit/`, REST protocol.
- **Docs:** BACKEND, NEXT-STEPS §1, DECISIONS.
- **Test:** `swift test --package-path packages/PlateSync` &&
  `swift test --package-path server` (41 tests, no database needed).
- **Status:** 2026-10-15 production schema export confirms deployment and creator-only
  submission roles. Hub capability and read-only connection diagnostics added; REST fallback
  port now matches server 8083. Signed installed Hub account access and native REST moderation
  refresh/reconnect verified; local per-user reference service restored. REST submissions now strip
  thumbnail bytes and reapply plate/location privacy (19 PlateSync tests, 53 server tests pass).
  Hub automatic queue delivery and CloudKit publication remain
  unfinished; schema deployment alone does not prove either. Receipts now carry optional idempotency and
  operator-confirmation metadata for audit surfaces. Intake and moderator state transitions now append
  content-free audit details. Public agency directory/report DTOs and REST routes now cross the shared
  sync boundary, with an iOS directory/detail surface; CloudKit aggregate report delivery remains a
  deployment gate. See [connection QA](BACKEND-QA-2026-10-15.md).
  The reference server also exposes the separate ephemeral presence endpoint;
  it never writes presence into CloudKit sightings or moderation records.
- CloudKit record-name identity is now deterministic across launches (SHA-256
  UUID derivation); receipt and delta reconciliation no longer depends on Swift's
  randomized `Hasher` seed. Review now exposes bounded delivery history and a
  **Recover CloudKit history** action for creator-readable submissions delivered
  by older Hub builds; it never restores private plate/frame/location payloads.
- **Next:** CloudKit moderator publication and two-account
  isolation tests. CloudKit/REST two-way mirroring and hosted deployment remain planned.

## WS6 — Trust & redaction (cross-cutting)

- **Owns:** `packages/PlateKit` model + `RedactionGate`, DTO
  field-compatibility, LEGAL-ETHICS encoding, moderation states.
- **Docs:** LEGAL-ETHICS, DATA-MODEL, AGENTS.md guardrails.
- **Test:** `swift test --package-path packages/PlateKit`.
- **Status:** gate + official-plate evidence landed; shared
  `PlateKit.FleetScoring.vehicleGateScore(gate:vehicle:)` is now used by iOS,
  EvalHarness and Hub. The wire DTO carries optional `userConfirmed`; Hub Review
  can bulk-confirm selected evidence, and explicit unconfirmed payloads remain
  pending at the reference server boundary.
- **Next:** add publication receipts and moderator-facing confirmation audit fields;
  run all package/server compatibility tests whenever this DTO evolves.

---

## Efficiency conventions (adopted)

1. **One scoring call site.** Fleet-confidence logic is invoked only through
   the shared PlateKit helper — no per-app copies (this caused the Hub
   breakage).
2. **Workstream-scoped sessions.** Agents/developers touch one workstream per
   change; shared-type changes go through WS6 and require running *all*
   package tests.
3. **Machine-readable status.** The Status lines above are the dashboard;
   ROADMAP.md checkboxes stay the milestone source of truth (only tick
   verified items).
4. **Recorded fixtures over live dependencies.** CI never depends on cameras,
   feeds, or CloudKit; live verification is a documented manual step.
5. **Citations everywhere** (`SourceCitation`) — enrichment without a source
   is rejected by code review and, once AccountabilityKit lands, by types.
