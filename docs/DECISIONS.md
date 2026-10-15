# DECISIONS.md — product and technical decisions log

One entry per decision, newest first. Each records the choice, the reason,
and what it commits us to. Superseded decisions stay here with a pointer to
the replacement.

## 2026-10-13 — Plate detector: home-trained Create ML model wins the head-to-head

**Decision.** `plate-detector-createml-v1` (0.2.0, single-file `.mlmodel`, 416×416
Create ML object-detection pipeline, trained 2000 iterations on Open Images V7
"Vehicle registration plate" boxes) becomes the registry's `plate-detection`
model, superseding the converted `plate-detector-yolov8n` (0.1.0, kept as
fallback).

**Measured (62-image corpus, full pipeline incl. vehicle detector).**
Plate reads 19/62 (Create ML) vs 17/62 (YOLOv8n) vs 12/62 (no detector);
fleet recall 63 % vs 61 % vs 61 %; precision 100 % and 0 civilian false
positives in all three configurations. A plate-only re-run (harness
`--tasks plate-detection`) agreed: 20/62 vs 18/62 reads, recall 63 % vs 61 %.
The Create ML model is also ~10× larger (31 MB vs 3 MB) — accepted for the
accuracy gain; ANE-resident at runtime.

**Provenance.** Training images are Google Open Photos/Flickr CC BY 2.0 with
Open Images CC BY 4.0 annotations — the full per-image list is committed at
`models/provenance/plate-detector-createml-v1.md` (guardrail 5). The YOLOv8n
weights remain AGPL-3.0, compatible with the project license.

**Packaging.** `.mlpackage` models cannot be single-file release assets, so
directory packages ship as Apple Archives (`.aar`) and are extracted on-device
by `VehicleML.ModelArchive` before `MLModel.compileModel`. The Create ML export
is a single `.mlmodel` file and ships raw. Artifact format is recorded per
registry entry (`format`: `mlmodel` | `aar`).

## 2026-10-11 — M4 heatmap granularity: agency aggregates with k-anonymity

**Decision.** Public aggregates are published per agency and per geohash-6
cell (~1 km), with a minimum bucket size **k = 5**. Any bucket below k is
withheld and reported as a count only. No individual paths or per-sighting
locations are ever published.

**Why.** Heatmaps and timelines are the main re-identification risk in this
project: a single vehicle's repeated cells reveal its route. k-anonymity
bounds that risk per published number, and the coarse cell size matches the
geo-bucketing rule already in LEGAL-ETHICS.

**Implementation.** `GET /v1/aggregates/heatmap` (server/Sources/App/AggregatesController.swift).
Window defaults to 30 days and is capped at 366. Only `fleetConfirmed` rows
count. Agency scoping needs vehicle linking, which is not automatic yet, so
agency results are sparse until linking ships.

**Commits us to.** k stays a single constant. Changing it is a policy change
and needs a note here. The API never returns per-sighting rows.

## 2026-10-11 — M2 vehicle re-ID: OSNet via PyTorch trace → CoreML

**Decision.** Replace the Vision feature-print fallback with OSNet x0.25
(MSMT17), traced from PyTorch and converted with coremltools. The ONNX
route is abandoned because coremltools 9.x dropped ONNX support.

**Status.** The converter path exists (`scripts/convert_models.py --task
vehicle-reid`). Conversion was started in this session; see HANDOFF for the
result.

**Licence.** Registry entry records MIT. Weights are not committed (AGENTS.md
guardrail 5).

## 2026-10-11 — M2 plate-design classifier: build a labeled dataset

**Decision.** Train our own state / exempt / federal plate-design classifier
on a labeled dataset, rather than wait for a pretrained model.

**Gate before any collection.** A licensing review of every image source,
recorded here, before a single image is downloaded. Plate crops of private
vehicles are out of scope for collection (LEGAL-ETHICS Rule 1): only public
government-plate examples and reference images of plate designs.

**Status.** Not started. Placeholder remains in the registry. The redaction
gate already treats a missing design as non-exempt, so nothing breaks while
this is pending.

## 2026-10-11 — M2 colour classifier: find a compatible model

**Decision.** Replace the broken MobileViT v2 colour entry with a model that
has a valid preprocessor and a recorded licence.

**Result of the search.** No suitable ready-made colour model found yet.
- `shripadd/car-color-detection` (Hugging Face): no model card and no
  licence statement, so it cannot be recorded under guardrail 5. Not usable.
- `dima806/car_models_image_detection` is Apache-2.0 but predicts car
  models, not colour. It is a possible backbone for fine-tuning.

**Next step (needs a call).** Either fine-tune a colour head on a permissively
licensed backbone with a colour-labelled dataset whose licence we can record,
or defer colour and use the vision baseline. CompCars, named in the old
roadmap, is to our understanding licensed for non-commercial research only.
Verify its terms before any use as training data for a project that may be
commercial.

## 2026-10-13 — Fleet evidence without our own models; human confirmation

**Decision.** Until fleet-specific CoreML models ship, use (1) door-text evidence with a graded
score, (2) Apple's built-in Vision classifier labels `police_car` / `firetruck` / `ambulance` /
`bus` as a *cue* (≤ 0.45 of the score, so never sufficient alone), and (3) a user-confirm step for
the 0.15–0.55 band that submits at the persist floor so the server files it as `pending`.

**Why.** On 62 real US photos this gave 100 % precision with 0 civilian false positives, 57 %
automatic recall and 76 % with confirmation (docs/EVALUATION.md). Lowering the automatic
threshold would have admitted decals and bystanders; human confirmation recovers recall without
touching precision.

**Guardrails kept.** A cue-only vehicle carries no plates; a plate joins a cue only when it is the
frame's single candidate. Plates must contain a digit. Nothing is public on a user's word alone.

## 2026-10-13 — CloudKit: separate submissions from published records

**Decision.** Device uploads go to `SightingSubmission` (creator-only read); published records are
world-readable and created only by moderator tooling. Plate text is uploaded only when the REST
server's own "fleet-confirmed" rule would publish it (≥ 0.8 with markings).

**Why.** The public DB has only a default zone and no per-record privacy, so putting pending
detections (and plates) next to public data would have broken LEGAL-ETHICS Rule 1.

## 2026-10-13 — Evaluation corpus is licensed + manifest-only

Images come from Wikimedia Commons under CC0/PD/CC-BY/CC-BY-SA, are kept out of git (some show
civilian plates), and only `eval/manifest.json` (source, license, author, labels) is committed.
We do **not** write fabricated sightings from these photos into any shared database.
## 2026-10-13 (later) — watch the powerful: person-records program (M7) adopted

**Decision.** The mission statement changes from "watches power, not people"
to "**watches the powerful**": public officials in their public capacity are
legitimate subjects (First Amendment photography in public, public-records
laws, Brady/Giglio disclosure practice), and aggregating already-published
public-interest reporting with citations is an explicit product goal
(`docs/ACCOUNTABILITY-DATA.md`). Private individuals remain out of scope
absolutely; the Rule-6 guardrails (no home/family data, no biometric matching
per BIPA/Tex./Wash., verbatim docket records, labeled inference, takedown)
are conditions for that program.

**Commits us to.** `AccountabilityKit` types with citation enforcement before
any collection code; moderator confirmation before any person-linked record
publishes; ethics review by the owner before ingest begins.

## 2026-10-13 (later) — monorepo + workstreams (PROJECTS.md)

**Decision.** Keep the single repository; organize work as six workstreams
(`docs/PROJECTS.md`) with per-workstream packages (`AccountabilityKit`,
`FeedIngest` joining the existing five), docs, and test commands. No
multi-repo split — versioning/CI friction outweighs the benefit at this
contributor count.

**Commits us to.** Dependency direction `PlateKit ← AccountabilityKit` and
`PlateKit ← FeedIngest`; workstream-scoped diffs; the shared
`PlateKit.FleetScoring` entry point replacing per-app scoring calls.

## 2026-10-13 (later) — name stays, scope retitled

**Decision.** Keep the name **PlateWatch** (repo, `org.platewatch.*` bundle
IDs, `iCloud.org.platewatch.platewatch` container, package names stay); all
user-facing copy retitles the scope: "open accountability infrastructure for
publicly funded fleets and the officials who run them." Renaming technical
identifiers this early would break CloudKit, signing, and URLs for cosmetic
gain. Revisit only if the umbrella ever outgrows vehicles+officials.

## 2026-10-14 — Rule 6 amended: on-device identification of recorded officials

**Decision.** The absolute biometric-matching ban of the 2026-10-13 M7
decision is superseded by a conditional authorization (LEGAL-ETHICS Rule 6):
face matching is permitted only against a corpus of people who already have
cited public accountability records (Brady/Giglio, decertification, dockets),
using cited public photos, computed on-device, never auto-publishing, and
only in deployments whose jurisdiction has passed counsel review. Private
individuals remain absolutely out of scope.

**Why.** Surfacing an official's cited public record at the moment they
appear on camera is the product's core accountability loop — the same
aggregation-with-provenance the M7 program already authorizes. An outright
ban made that loop impossible even under conditions that respect the
statutes; the conditions (recorded subjects only, public photos only,
on-device, confirmation, jurisdiction gate) address the statutory exposure
directly instead.

**Commits us to.** `AccountabilityKit` keeps matching code behind the
jurisdiction/consent gate (off by default, enablement recorded); biometric
templates never leave the operator's device; matches are labeled inference
and require moderator confirmation before any publication; the SafetyHold
takedown/appeal process applies to person links.
