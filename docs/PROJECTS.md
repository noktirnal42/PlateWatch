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
- **Status:** still-photo core loop inherited; 2026-10-14 iOS review/branding pass
  adds observation detail/export, retry recovery, validated fleet watchlists,
  local cleanup and simulator CloudKit startup-crash fix. See
  [IOS-UI-HANDOFF.md](IOS-UI-HANDOFF.md) for validation and screenshot boundaries.
  Handheld live-camera field testing remains pending.
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
- **Status:** 2026-10-14 desktop console builds and runs; favorites/block, shared polite polling,
  Caltrans's scoped robots fallback, selected snapshot analysis in Live, and moderator audit refresh
  implemented. Feed browser state survives sidebar navigation; Records & FOIA exposes the fleet FOIA
  builder, a cited public-records directory and the programme boundary. Merged with the evidence-image
  work: recorded fleet hits carry redacted vehicle crops (≤40 KB JPEG + SHA-256), shown as Review-pane
  thumbnails with click-to-enlarge. `.hls` feed entries now run continuous background analysis through
  `FeedIngest.HLSFrameSource` (same gates/tiering/crops as snapshots; manifest-origin robots; AVPlayer's
  own CDN segment fetches are a documented limitation); `.rtsp` states it needs the unbundled VLCKit
  fallback. Oregon/Utah/New Mexico imports added; new hosts remain unconfirmed. Continuous HLS and raw
  RTSP are not yet validated against real streams end-to-end.
- **Next:** follow [HUB-HANDOFF-2026-10-14.md](HUB-HANDOFF-2026-10-14.md): verify a real permitted HLS
  camera end-to-end,
  credentialed US sources, hardware/permission QA and a small camera-quality pilot.

## WS3 — Recognition & evaluation

- **Owns:** `packages/VehicleML`, `eval/`, `models/`, model registry,
  conversion scripts.
- **Docs:** EVALUATION, NEXT-STEPS §3–5, PLATE-DESIGN-DATASET, DECISIONS.
- **Test:** `swift test --package-path packages/VehicleML` +
  `EvalHarness eval [--models models/cache]`.
- **Status:** baseline 59 % auto recall / 100 % precision (62-image corpus);
  official-plate reading landed; CoreML plate detector lifts plate reads
  10→15/62 images; vehicle-detector fusion fixed to not erase text-inferred
  fleet class. Plate OCR model + ground-truth labels still open.
- **Next:** ground-truth `plate` labels + exact-match/CER scoring in the
  harness; grow corpus (USA, licensed, challenging low-contrast examples);
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
- **Status:** schema written, not imported (owner Apple-account step);
  moderator publish tool not started; REST mirror not deployed.
- **Next:** import + deploy `cloudkit/schema.ckdb`; moderator publish CLI;
  verify `_creator`-only roles; optional mirror hosting.

## WS6 — Trust & redaction (cross-cutting)

- **Owns:** `packages/PlateKit` model + `RedactionGate`, DTO
  field-compatibility, LEGAL-ETHICS encoding, moderation states.
- **Docs:** LEGAL-ETHICS, DATA-MODEL, AGENTS.md guardrails.
- **Test:** `swift test --package-path packages/PlateKit`.
- **Status:** gate + official-plate evidence landed; **known drift risk** —
  three call sites hand-roll the scoring call (iOS, EvalHarness, Hub) and the
  Hub already broke once when the signature changed.
- **Next:** add `PlateKit.FleetScoring.vehicleGateScore(gate:vehicle:)` as the
  single scoring entry point and adopt it in iOS/EvalHarness/Hub so signature
  evolution cannot desync callers; DTO `userConfirmed` field (NEXT-STEPS §8).

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
