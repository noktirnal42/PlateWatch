# DECISIONS.md — product and technical decisions log

One entry per decision, newest first. Each records the choice, the reason,
and what it commits us to. Superseded decisions stay here with a pointer to
the replacement.

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
