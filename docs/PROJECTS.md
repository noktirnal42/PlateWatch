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
  tuning and clip export remain QA/follow-up gates. The iOS simulator scheme's six UI review-flow
  tests are covered, including landscape, large text, local cleanup, retry/discard, detail, and watchlist flows;
  the latest simulator run exposed an accessibility-scroll failure on the keyboard Done key; the large-text
  watchlist flow now scrolls boundedly to the fleet-attestation control and the targeted simulator rerun passed.
  Handheld live-camera field testing remains pending. The simulator now proves the REST health path and
  renders the published-fleet feed (empty state is explicit when the backend has no published records);
  signed CloudKit account/database verification remains external. CloudKit watchlist subscription registration,
  watchOS silent-push delta matching, haptics and local alert presentation are implemented; signed
  entitlement and physical-device push delivery remain external QA gates.
  The phone now mirrors its normalized local watchlist to the companion watch
  through WatchConnectivity; pairing and push delivery remain physical-device gates.
  iOS capture now stages cached vehicle/plate detectors before the optional vehicle-type artifact,
  matching Hub behavior when the registry or classifier is unavailable.
  The watch root observes its extension delegate directly, so push-delivered hits and unread counts
  update in the visible Recent fleet hits list as well as the complication.
  The watch now also presents the Hub dashboard's aggregate counters in a compact Live stats section.
  The section refreshes when the app returns to the foreground, on its 30-second visible timer,
  and exposes one stable accessibility surface for device QA.
  Only numeric processing/presence totals cross the ephemeral presence endpoint; frame bytes, plates,
  locations, and evidence remain local. Missing Hub counters render as `—` until a Hub heartbeat arrives;
  a failed heartbeat now clears the cached ephemeral counters so a disconnected watch cannot show stale
  active-user or processing totals.
  2026-10-17 wireless device pass: the current signed iOS and watchOS builds installed on the paired
  iPhone 16 Pro Max and Apple Watch Series 9. The watch companion launched and its Recent fleet hits /
  Quick log surface rendered; the iPhone remained locked when devicectl attempted foreground launch, so
  its installed-app foreground screenshot is pending an unlock. The current signed iOS build installed
  and launched on the connected iPhone;
  portrait and landscape captures show the controls and overlay canvas rotating together. The current
  watchOS build installs and launches on the connected watch; the physical screenshot shows the Live
  stats section with unavailable counters rendered as `—` while the presence heartbeat is absent.
  iOS Live overlays now use the same neutral-label rules as Hub: unknown vehicles no longer display a
  misleading 0% class score, and a coarse colour cue is shown when available. The simulator UI suite
  passes the capture, review, and watchlist fixture tests; the two keyboard-sensitive tests were rerun
  on 2026-10-17 and passed 2/2. Xcode still hangs in post-test cleanup after reporting the successful
  result, so the cleanup symptom is tracked separately from the product test result.
  The overlay is now one VoiceOver element with a per-vehicle spoken summary (body class, colour, fleet label
  and confidence where available), plus a stable accessibility identifier for UI audits. The watchlist now
  provides an explicit keyboard-toolbar Done action. The debug capture fixture now renders one fleet SUV
  plus ordinary sedan and pickup classes, and the targeted UI audit passed 1/1 on the connected iPhone 17 Pro
  simulator (`/tmp/pw-ios-sim-qa`, 6.464 seconds). The physical iPhone and watch are currently reported
  unavailable by `devicectl`, so this is simulator evidence rather than a new physical-device claim.
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
  The dashboard now distinguishes live presence from an unavailable presence service and reports that
  local feed processing continues instead of showing stale active-session counts.
  Dashboard stat cards now expose stable identifiers and explicit label/value semantics for VoiceOver
  and automated visual QA, including the presence counters.
  Moderation now probes the reference server's unauthenticated health endpoint separately from the
  moderator queue, so server outages and expired moderator credentials are shown as different states.
  Review multi-rejection/enlargement and pane persistence repaired; original eight queued records
  preserved (their payloads lacked image bytes before this repair). Snapshot failures, policy failures
  and manual recovery are distinct. The current NV511 catalogue has 652 paired snapshots polling;
  selected HLS sources fall back to their paired snapshot when the provider decoder cannot deliver
  a frame. OpenCode watch controls reconciled: persisted selective polling,
  four-stream HLS budget and Live priority; watch scan hang fixed and native toggling verified.
  Local Review preserves intact evidence crops: overlapping vehicles and foreign text no longer
  remove or black out photos (owner clarification, 2026-10-15; 37 Hub tests, four opt-in skips).
  Child-resource/redirect policy relay and bounded preview slots implemented and native NV511 playback verified;
  165 FeedIngest and 50 Hub tests pass (four Hub opt-in skips). The loopback relay now also parses
  malformed request lines through a bounded 405 path without unsafe token access. HLS watch slots rotate every minute
  with Live pinned; explicit filter reset/reload restores the complete visible catalogue.
  The feed browser now has a persisted-safe Reset view action that also returns from Favorites/Blocked scope
  to the complete catalogue, preventing cameras from appearing lost after relaunch.
  When the NV511 key is present, the browser exposes a one-click Refresh NV511 action beside the watch controls;
  it merges the current keyed catalogue without requiring the operator to open the source menu.
  HLS Live now bounds a selected decoder attempt to 15 seconds and exposes a Retry action that tears down
  the stale player before restarting it; this makes provider segment failures visible and recoverable.
  NV511 refreshes now merge the current keyed catalogue; a failed Live preview performs one five-minute-cooldown
  route refresh and retries the stable camera ID before falling back to its paired approved snapshot view, with an
  explicit status preserving a usable camera while the provider repairs video. Live now starts that paired snapshot
  fetch in parallel with the bounded HLS attempt and normalizes camera names across catalogue punctuation, so a
  usable approved image appears during slow decoder recovery instead of leaving the pane blank.
  The feed browser now exposes an explicit Watch NV511 action for all confirmed Nevada sources; snapshots remain
  host-throttled and HLS stays within the rotating four-stream budget.
  Feed status now reports active versus queued HLS rotation explicitly, so queued NV511 cameras are not mistaken
  for lost feeds while their paired snapshots continue polling. The latest Live repair reserves one of the two
  analysis slots for the selected camera, so a full watched catalogue cannot starve Live; HLS failures now report
  paired-snapshot delivery and local-analysis failures separately.
  The relay pins the root playlist capability while bounding child-resource routes, preventing long-lived live
  streams from evicting the URL AVPlayer is polling.
  When live presence sharing is enabled, each feed row now shows its current processor count, `0`, or an
  explicit unavailable marker instead of hiding the demand state.
  The Hub status popover repeats that recovery action and shows the confirmed NV511 count, so a relaunch that
  leaves the catalogue idle can be repaired without navigating away from the dashboard.
  A duplicate Hub-process regression was reproduced during NV511 QA: two schedulers shared the same local store and
  made Live controls appear hung. The installed Hub now keeps one oldest instance, closes a newer duplicate before
  it starts feed services, and was reinstalled with 10,590 catalogue entries visible after clearing the persisted
  Favorites scope. The live bridge then reported 666 watched feeds and fresh NV511 HLS/snapshot frames.
  Local evidence has hash-addressed recovery copies, and Live shows generic vehicle classes (including
  readable SUV/van/pickup/sedan/motorbike aliases and classifier confidence when a body label is unavailable).
  iOS now exposes the public agency directory and REST-backed report-card detail flow through the shared
  sync boundary; CloudKit directory records are supported, while aggregate report delivery remains a
  deployment/mirror gate until the required public records are present.
  CloudKit-entitled Hub delivery retains local acknowledgement receipts and
  identifies CloudKit versus the separate REST moderation queue. Review can
  recover creator-owned history, explicitly hand it through the REST privacy
  gate into the Moderation queue, or invoke the guarded moderator-only
  `CloudKitBackend.publish(_:)` path for confirmed fleet submissions. Automatic
  mirroring, credentialed production publication, and two-account isolation
  remain deployment/account gates.
  The Hub now has an opt-in ephemeral presence lease that reports live processor
  totals and per-feed demand through the REST boundary; leases expire after 90
  seconds and are never persisted. The iOS capture path contributes an opt-in
  ephemeral active-processing lease, and the watch companion contributes an
  in-use lease while foregrounded; both use the same non-persistent REST
  presence boundary as Hub. The watch also receives the Hub's aggregate
  processing counters for its Live stats section; hosted deployment and
  accessibility validation remain follow-up gates.
  Sustained pilot, unsupported playlist forms and physical QA remain.
- **Visual polish:** screenshot-checked Dashboard, feed browser and Sandy Live view; native-symbol metrics, dashboard shortcuts, camera/host rows and optional readable overlays. Actual Dashboard capture added to Pages source. Minimum-width feed status clipping fixed; console-only System/Light/Dark controls and ⌘1–⌘8 navigation added. Actual menu/key/overlay-checkbox interactions verified; System appearance and original window size restored.
- **Court-search results:** each CourtListener/PACER search replaces the Current search view immediately; empty/error responses remain empty and late older responses are ignored. Saved pending and accepted records stay available in separate tabs. Regression coverage includes repeat-search deduplication and stale completions.
- **Agent interface:** authenticated app-owned commands + local MCP/skill; [integration and internal-agent plan](AGENT-INTEGRATION.md). Local MLX and on-device Foundation Models now complete bounded tasks in the signed Hub; seven agent-core tests and 50 Hub tests pass (four Hub opt-in skips). Stop/journal verified. Owner-selected NVIDIA hosted agent/retrieval/extraction/vehicle-benchmark integration is implemented; live endpoint corrections and limits are recorded in the NIM research report. PCC remains pending.
- **Next:** extend the mediated real-camera proof into
  a sustained quality/freshness/CPU pilot and broader internal-agent task/attribution evaluation
  in AGENT-INTEGRATION.md. Credentialed source expansion and physical hardware/permission QA remain.
  Current continuation evidence and remaining gates: [repair report](HUB-REPAIR-2026-10-15.md).
  2026-10-16 physical QA: the newest signed iOS build installed and launched on iPhone 16 Pro Max;
  portrait and landscape device screenshots show the capture UI with the camera active and all-vehicle
  class overlays. Capture now reports a first-frame health state instead of claiming scanning before
  AVCapture delivers a sample buffer. A real moving-traffic/low-light drive exercise remains open.
  Signed watch companion installed and launched on Apple Watch Series 9; the recent-hits
  and Quick log surface rendered successfully. The watch now includes notification
  permission, visible unread-hit state, and a WidgetKit complication with fleet-hit and
  opt-in active-user counts. Camera permission/real-scene capture and CloudKit push
  delivery still require an operator field exercise. The latest physical install and
  launch passed after correcting the WidgetKit extension bundle metadata. Watch hit rows
  and Quick Log now expose spoken labels and hints for VoiceOver; a signed generic watchOS
  build passed, while a repeat physical install is pending the device tunnel reconnecting.

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
  A deterministic coarse RGB crop cue now fills a low-risk vehicle colour attribute for generic detections;
  it is deliberately excluded from fleet scoring and does not claim make/model recognition (39 VehicleML
  tests, one local-image opt-in skip).
  Hub Live now includes that colour alongside the readable body class in each overlay, while retaining the
  fleet label and score as separate fields (50 Hub tests, four opt-in skips). OCR is now an enrichment
  pass: Vision image-reader failures preserve the frame and generic vehicle geometry instead of dropping
  the entire analysis (39 VehicleML tests, one local-image opt-in skip). The optional licensed
  `vehicle-type-classification` model is now installed by Hub and iOS and applied to up to eight detected
  crops per frame, filling missing coarse body types without changing fleet gating (41 VehicleML tests,
  one local-image opt-in skip). The model manager now caches and bundles a core registry and installs
  cached vehicle/plate detectors before attempting the optional classifier, so a registry outage or
  missing type artifact cannot silently return the Hub to baseline mode (42 VehicleML tests, one
  local-image opt-in skip).
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
  (local only, `docs/ACCOUNTABILITY-DATA.md`). People tab (operator-side cited links) built. Roster CSV importer and an eight-source one-click police roster catalogue built; person-level import, citation-only storage, pending review, and hidden unit links are covered by 39 AccountabilityKit tests. Second-person moderation is implemented behind `REQUIRE_SECOND_REVIEW=1` and its shared policy is covered by server tests. Any publication remains external/deployment-gated.
- **Validation:** the opt-in CourtListener smoke test reached the live v4 endpoint on 2026-10-16 with the public
  query `police` and returned 20 parseable dockets; PACER remains unexercised because it requires the owner's account.
- **Next:** exercise PACER live (owner testing, free allowance); read statute text for the FOIA
  deadline table (VA unconfirmed, CA AB 1821 pending).

## WS5 — Sync & backend

- **Owns:** `packages/PlateSync`, `server/`, `cloudkit/`, REST protocol.
- **Docs:** BACKEND, NEXT-STEPS §1, DECISIONS.
- **Test:** `swift test --package-path packages/PlateSync` &&
  `swift test --package-path server` (33 PlateSync + 57 server tests, no database needed).
- **Status:** 2026-10-15 production schema export confirms deployment and creator-only
  submission roles. Hub capability and read-only connection diagnostics added; REST fallback
  port now matches server 8083. Signed installed Hub account access and native REST moderation
  refresh/reconnect verified; local per-user reference service restored. REST submissions now strip
  thumbnail bytes and reapply plate/location privacy (33 PlateSync tests, 57 server tests pass).
  Hub automatic queue delivery and CloudKit publication remain
  unfinished; schema deployment alone does not prove either. Receipts now carry optional idempotency and
  operator-confirmation metadata for audit surfaces. Intake and moderator state transitions now append
  content-free audit details. Public agency directory/report DTOs and REST routes now cross the shared
  sync boundary, with an iOS directory/detail surface; CloudKit aggregate report delivery remains a
  deployment gate. See [connection QA](BACKEND-QA-2026-10-15.md).
  The reference server also exposes the separate ephemeral presence endpoint;
  it never writes presence into CloudKit sightings or moderation records.
  Its public read-only surface now covers CSV/GeoJSON exports, the k-anonymous heatmap page, agency directory/report
  pages, and the corresponding `/v1` mirror routes; no browser write path is exposed.
  A multi-stage `server/Dockerfile` and deployment notes package the REST mirror with
  Swift 6.2 and bind its health/API surface on `0.0.0.0:8083`; the `linux/arm64` image
  was built successfully as `platewatch-server:qa` on 2026-10-16, and the server suite
  passed 56 tests with zero failures. Running the image against a production database
  and deploying it remain external gates.
- CloudKit record-name identity is now deterministic across launches (SHA-256
  UUID derivation); receipt and delta reconciliation no longer depends on Swift's
  randomized `Hasher` seed. Hyphenated idempotency keys now preserve their full
  record-name identity during public delta pulls, so CloudKit sightings reconcile
  with the same receipt ID. Review now exposes bounded delivery history and a
  **Recover CloudKit history** action for creator-readable submissions delivered
  by older Hub builds; it never restores private plate/frame/location payloads.
- CloudKit history recovery now follows every query cursor instead of stopping
  at the first 200 creator-owned submissions, so older receipts and pending
  handoffs remain recoverable after a large sync backlog.
- Creator-owned submission IDs are now scoped by a one-way device hash, so equal
  content from separate accounts cannot collide before creator ACLs apply while
  the content idempotency suffix remains stable for local retries.
- The moderator publication boundary is now a tested `Sighting` record builder:
  it requires confirmation plus fleet evidence and strips creator-only device
  and review fields. `CloudKitBackend.publish(_:)` now performs the guarded
  moderator save with idempotent record identity and explicit permission/quota
  errors; saving with a moderator credential remains a deployment gate.
- A reference Python edge client now implements the stable REST submission contract for a Raspberry Pi/OAK-class processor.
  It accepts only explicit operator-confirmed fleet observations, rejects exact coordinates and review/raw image bytes,
  uses the same content-addressed idempotency digest as `OutboxDrainer`, and is covered by four standard-library fixture tests.
- The first Android target now builds a read-only public-sightings client against `/v1/sightings`, with an explicit mirror
  endpoint, DTO parsing, and an empty-state/error surface. It requests no plates, crops, raw frames, or exact coordinates;
  ONNX capture inference is deliberately still open pending a licensed model and measured device benchmark.
- **Next:** credentialed CloudKit moderator publication and two-account
  isolation tests. CloudKit/REST two-way mirroring and hosted deployment remain planned.

  A signed Hub rebuild on 2026-10-17 repaired a local installation regression where an
  unsigned CI-style app had replaced the operator build and therefore reported no CloudKit
  entitlement. The rebuilt app was verified with the container entitlement and its live Settings
  probe reported `Connected · public database readable`. The new
  `apps/macos-hub/scripts/build_signed_and_install.sh` path refuses to install a build without
  that entitlement; CI remains intentionally unsigned.

## WS6 — Trust & redaction (cross-cutting)

- **Owns:** `packages/PlateKit` model + `RedactionGate`, DTO
  field-compatibility, LEGAL-ETHICS encoding, moderation states.
- **Docs:** LEGAL-ETHICS, DATA-MODEL, AGENTS.md guardrails.
- **Test:** `swift test --package-path packages/PlateKit`.
- **Status:** gate + official-plate evidence landed; shared
  `PlateKit.FleetScoring.vehicleGateScore(gate:vehicle:)` is now used by iOS,
  EvalHarness and Hub. The wire DTO carries optional `userConfirmed`; Hub Review
  can bulk-confirm selected evidence, and explicit unconfirmed payloads remain
  pending at the reference server boundary. Submission receipts now carry the
  idempotency key and operator-confirmation state, including idempotent replay;
  REST intake and moderator decisions append content-free confirmation audit fields.
- **Next:** continue package/server compatibility tests whenever this DTO evolves;
  CloudKit production publication and two-account isolation remain WS5 deployment gates.

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
