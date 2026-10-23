# PlateWatch implementation audit — October 23, 2026

## Scope and conclusion

Inspected development commit `220c7f1`, the roadmap, workstream dashboard,
next-steps/handoff documents, model registry, CI/Pages configuration, relevant
Hub code and the local TrafficView source. Implementation in this audit is on
`feat/hub-moderation`, ahead of `main`; publishing this audit does not merge
that development stack. This is a working pre-alpha, not a completed release.
This checkpoint develops WS2 (Hub), with documentation reconciliation across
milestones; shared DTOs and privacy gates are unchanged.

The biggest gap is now acceptance evidence and integration, alongside model
quality. README, Pages, NEXT-STEPS and early training notes still contained
claims superseded by code and later dated reports. A view or published model
asset alone does not prove the corresponding workflow is complete.

## Specs versus implementation

| Area | Implemented / evidence | Remaining acceptance work |
|---|---|---|
| M-Alpha capture/review | Photo loop, local review, human fleet confirmation, receipts, retry/withdrawal, event clips; prior simulator and physical install/launch reports | Handheld daylight/dusk/moving-traffic exercise, thermal run, spoken accessibility, production withdrawal |
| M1 capture quality | Lens/exposure controls, event buffer, multi-frame fusion, watchlists | Physical motion/exposure tuning and field false-positive/false-negative evaluation |
| WS2 / M6 Hub | Folder/Bonjour/camera sources, policy-mediated HLS, moving AVPlayer surface, bounded watches, map, favorites/blocks, review archive | Sustained freshness/CPU/memory pilot, actual hardware permissions, unsupported playlists, separately licensed raw RTSP decoder |
| M2 recognition | Project-trained plate detector released; generic detector and type model; colour heuristic; Vision OCR | Fleet-crop classifier, calibrated plate-state model, evaluated make/model and vehicle re-ID integration, specialized OCR |
| M3/M7 records | GSA/city/auction/VIN importers, FOIA drafts/tracker, roster/court/list candidates, cited profiles/unit links, RSS/Atom | Wider source coverage and licence notes, PACER owner-account exercise, false-link/moderator acceptance, reviewed publication |
| WS5 sync | Local receipts, owner-scoped CloudKit submissions, explicit REST handoff, guarded publishing and server-to-server publisher, tombstones | Credentialed production publication, live two-account isolation, deployment/population of public report data |
| CloudKit schema | Production schema exports/deployment are recorded in BACKEND and later status notes, including presence | Schema evidence is not proof of public delivery, push delivery or account isolation; not re-exported in this audit |
| M4 interfaces | Agency directory/reports, aggregate map/timeline, watch subscriptions/stats/complication | Hosted aggregate data, physical push/haptic test, field/accessibility QA; CarPlay entitlement and device test |
| Agents/automation | Authenticated MCP; bounded Apple/MLX agent; opt-in NVIDIA public research; RSS timed refresh and watched-feed analysis | Task success/attribution evaluation, reviewed proposed links, resource budgets under load; PCC remains unimplemented |
| M5 other platforms | REST container/compose, Python edge client, read-only Android client, public web explorer | Hosted deployment, Android/edge device execution and inference acceptance; static Pages is not the live backend |

## Model backlog: train versus integrate

1. **Plate-state/design:** latest recorded baseline remains about 72% test
   accuracy on a small scan/crop set. The October 20 fifth run records 72.1%;
   October 22 collection adds state-agency specimens without retraining.
   No accepted model is registered. The actual shipping bar is at least 95%
   precision at 60% coverage on held-out real photos, with abstention,
   calibration, per-state results and the Minneapolis/Waltham regressions.
   More specimen images alone do not satisfy it. See
   [the specification](PLATE-STATE-CLASSIFIER-SPEC.md) and
   [training log](MODEL-TRAINING.md).
2. **Fleet/civilian:** train on vehicle crops, not whole scenes. Include
   civilian look-alikes and preserve the existing fleet thresholds. Earlier
   scene classifiers plateaued; see the crop recipe in MODEL-TRAINING.
3. **Make/model and colour:** make/model weights are already released;
   integration, licence/provenance checks and US-fleet evaluation precede
   retraining. Colour currently uses a conservative heuristic. Train only
   against a measured improvement target.
4. **Vehicle re-ID:** an OSNet asset is released, but its registry says it
   was trained on a person re-ID dataset. That does not establish vehicle
   matching quality. The active feature-print fallback is not replaced merely
   because the asset exists; evaluate vehicle-trained embeddings and false
   matches. Keep this distinct from single-camera box tracking.
5. **Specialized plate OCR:** Vision currently reads detector crops. TrOCR
   conversion/integration remains open; compare normalized exact-match and
   character error rate on the same holdout before adopting it.

Already released: the Create ML plate detector, YOLO plate fallback, generic
vehicle detector and optional vehicle models in `models-v0.1.0`. Neither the
state classifier nor a trained fleet-crop model should be advertised as shipped.

## TrafficView comparison and next tracking work

Read TrafficView's `Vision/IoUTracker.swift`, `AnalysisPipeline.swift`,
`VoteTally.swift`, `Video/HLSDecoder.swift` and design notes directly. It was
not launched during this comparison. **Run only one camera-consuming app at
a time**: the owner reports frozen cameras when TrafficView and PlateWatch
both connect. A valid comparison uses the same saved clip sequentially, not
simultaneous provider connections.

PlateWatch already adopted moving playback, stable track IDs, label voting,
box smoothing/velocity glide, uncertain dashed boxes and a fast detector-only
path separate from full fleet analysis. The latest source schedules a full
pass roughly every 1.2 seconds; detector sampling rate is a target, not a
measured guaranteed frame rate.

TrafficView additionally bounds classification to four tracks per frame,
runs heavy models every ten frames per track, requires a 48-pixel crop side
(and 160 pixels for make/model), uses confidence-weighted attribute votes
with minimum evidence, and uses a stricter IoU threshold across detector
classes. PlateWatch's full pass still repeats broader work. The next useful
comparison is per-track classification scheduling and crowded-frame fairness,
with ID switches, missed tracks, detector/full-pass latency and CPU measured
on identical clips. Do not copy a faster display path in a way that permits
quick detector frames to score or persist fleet records.

## Development delivered in this checkpoint

Live previously used analysis age to claim `NO NEW FRAMES`, which could
misdiagnose busy inference as a frozen camera. Delivery now uses the runner's
last received sample independently from analysis age. HLS delivery becomes
late after six seconds; snapshots allow twice their configured interval with
a 60-second floor. Unchanged snapshot bytes are a separate informational state.
The header remains visible with overlays disabled; the HLS HUD stops showing
a green Live chip when delivery is late. Four deterministic tests cover busy
analysis, delayed delivery, snapshot cadence/unchanged content and clock skew.
Offline help now explains this distinction and uses the current cyan/green
box legend.

## Verification

- FeedIngest: 171 tests, four opt-in skips, zero failures.
- Hub baseline: 62 tests, four opt-in skips, zero failures.
- Hub with delivery/analysis fix: 66 tests, four opt-in skips, zero failures;
  includes eight inherited live tracker regressions and four new health tests.
- PlateKit: 84 tests; CaptureKit: 18; VehicleML: 45 (one skip);
  PlateSync: 48; FleetImporters: 38; zero failures in these local runs.
- AccountabilityKit: 51 tests (one opt-in skip); reference server: 68 tests;
  zero failures. Agent-package verification is pending dependency resolution. No new handheld/device, classifier-quality,
  production-publication or two-account claim is made by these unit runs.
- Remote run `38985547075` failed the Hub build and iOS UI job. Its package,
  server, eval-harness, model-pipeline and MCP jobs passed. This is an older
  repair-branch run; current local tests do not establish current remote CI.

## Ordered continuation and release acceptance

- [ ] Sequential saved-clip tracking benchmark against TrafficView patterns;
  per-track heavy-classification budget with fairness and false-link regressions.
- [ ] Sustained single-app approved-feed pilot: deliveries, analysis throughput,
  errors, memory and CPU; preserve the policy relay and existing watch budget.
- [ ] Plate-state real-photo holdout and calibration, then crop-fleet training.
- [ ] Complete cited intake → deduplication → proposed link → human review;
  test corrections, rejections and citation retention. No automatic acceptance.
- [ ] Credentialed production publisher + two-account isolation + takedown test.
- [ ] Physical iPhone/watch field, push/haptics, accessibility and thermal QA.
- [ ] Hosted REST and Android/edge acceptance; restore green app/UI remote CI.

Facial matching is unbuilt. The implementable automation continuation is
non-biometric vehicle/unit matching and citation-backed records assistance,
with human review and the location firewall retained; no face identification
is included in this checkpoint.

### Signed runtime check

Signed, CloudKit-entitled Hub build, installation and launch succeeded.
The approved existing MGM HLS source reopened through the app command bridge.
The native UI displayed `Waiting for a frame · Awaiting analysis` while the
provider connected. The freshness header remained visible when Overlays was
turned off; the original enabled preference was restored. No new decoded-frame
or sustained-throughput claim is made from that connection attempt. TrafficView
was not running. A concurrent test attempt hit Xcode's build-database lock;
verification was rescheduled after the signed build finished.
