# PLATE-STATE-CLASSIFIER-SPEC.md — research, plan and spec for plate-state recognition

Status: **plan + first baseline (2026-10-19).** P2 (crawl) and P4 (headless baseline) ran; result is below the acceptance bar — see MODEL-TRAINING §7. No model is registered or wired in. (Original wording: plan only, nothing trained.) This extends, and does not replace,
[PLATE-DESIGN-DATASET.md](PLATE-DESIGN-DATASET.md) (licensing gate), [MODEL-TRAINING.md](MODEL-TRAINING.md) §4c and the
"Known gap" in [IDENTITY.md](IDENTITY.md). Research notes are from web searches on 2026-10-19; every licence below must be read
on the source's own page before any file is used.

## 1. The problem, stated precisely
Apple Vision cannot read a small state banner (the Minneapolis squad plate: "Minnesota", cursive, ~12 px tall). The identity
resolver therefore has a place name ("Minneapolis") without a state and asks the operator "which one?". We need a **state
estimate with calibrated confidence and an abstain option**, derived from the plate's *design* (colours, layout, graphics, banner
shape) rather than from reading it. Output feeds the existing resolver as a *prior*, never as a fact.

Non-goals: reading plate numbers (separate stages), identifying people or private vehicles, anything that uploads a frame.

## 2. What exists already (research result: no drop-in model)
| Candidate | Finding | Verdict |
|---|---|---|
| Hugging Face models | Search found no US plate **state** classifier; closest is a ViT fine-tune that separates six *countries* (`Manasee27/locater_ai1`) | Not usable |
| Nyckel pretrained plate classifier | 2-class (plate / not plate) | Not usable |
| Commercial ALPR APIs (e.g. region output) | Require uploading frames to a third party | **Rejected** (AGENTS.md rule 3) |
| Kaggle `gpiosenka/us-license-plates-image-classification` | 56 classes (50 states, DC, territories), ~128×224 px images per a third-party write-up; **licence not confirmed** (page is script-rendered, needs a Kaggle account to download) | Candidate for *evaluation only* once the licence is read; account/credentials are a human step |
| HF `UniDataPro/united-states-license-plate-dataset` | tags include CC BY-NC-ND 4.0; full set is sold | **Reject** (non-commercial/no-derivatives) |
| HF `ud-smart-city` US plate sets | labelled by plate text, free part is a 5-row sample | Reject |
| Wikimedia Commons "License plates of the United States by state" | 58 sub-categories; ~5,300 files sit directly in the state categories (more in sub-categories); per-file licences (PD / CC0 / CC BY / CC BY-SA); coverage is uneven (Delaware 31, North Dakota 32, Hawaii 35, … California 299) | **Primary source**; crawler exists (`scripts/crawl_commons_plates.py`) |
| Open Images V7 plate boxes (CC BY 2.0) | Detection boxes, mostly UK; no state label | Detector data only |
| State DMV design pages | Official images; licence/permission differs per state | Case-by-case, owner decision |

Conclusion: **train our own**, from CC-licensed reference images plus our own locally confirmed fleet crops, evaluated on real photos.

## 3. Architecture
```
frame → plate detector (existing) → plate crop → [PlateDesignClassifier] → top-k states + confidence
                                                        │
location prior (camera geohash / device-at-capture) ────┤
agency text / identity resolver (Minneapolis → MN|NC|KS)┘ → fused state distribution → resolver
```
- **Stage A – design classifier.** Core ML image classifier on the plate crop, ~56 classes + `unknown_other`. Input: plate crop,
  resized with aspect preserved (plates are ~2:1). Output: probability vector.
- **Stage B – fusion (PlateKit `Identity`).** Multiply the classifier distribution by the location/agency candidates the resolver
  already has ({MN, NC, KS} for "Minneapolis"). Fusion can only *rank among candidates the other evidence already allows*
  unless the classifier is very confident; a disagreement keeps the operator question.
- **Abstain rule.** Report a state only if top-1 ≥ threshold *and* top-1 − top-2 ≥ margin, thresholds chosen on validation data to
  hit ≥ 95 % precision; otherwise "unresolved". Government/exempt plates keep their separate family mapping
  (`RedactionGateService`, unchanged).
- **Provenance.** Every estimate carries a `SourceCitation` naming the model, version, `models/registry.json` entry and the
  training-data manifest hash. The estimate is shown as "design looks like MN (74 %)", never as a plate fact.

## 4. Data plan
1. **Reference set (bulk).** Run the existing crawler (CC0 / PD / CC BY, plus CC BY-SA by the 2026-10-13 owner decision, for this
   classifier only) → `training/plate-state/<State>/` + manifest of source page, licence, author per file. Skip historic years
   (< 1990) and trailer/motorcycle/temporary/dealer titles (already in the crawler). Target ≥ 100 usable images per state; states
   under ~60 (DE, ND, HI, ID, RI, SC, territories) get extra from sub-categories and, if the owner approves, DMV pages.
2. **Real-photo set (what the model must actually work on).** Plate crops from *in-situ* Commons photos and from the operator's own
   fleet captures. Fleet labels come for free and are human-checked: a confirmed fleet vehicle whose agency resolves to
   `US-<state>-…` gives the state label for its plate crop. These stay **on this Mac**, are used only for local training/eval,
   and are never uploaded or published (Rule 1; Review evidence is never routed to models).
3. **Synthetic variation, not substitution.** Because the target is a 40–120 px-wide plate in a phone/DOT-camera frame, augment the
   flat scans by down-scaling to 40–160 px wide, perspective ±25°, motion/defocus blur, JPEG 30–90, glare, rain streak, night
   colour cast. Never train on a state's scans alone without real-photo validation for that state.
4. **Splits.** By *source photographer/uploader* (as `make_classifier_dataset.py --group-by-author`), so near-duplicate shots of the
   same plate cannot leak into validation. Run the existing overlap check against `eval/manifest.json`.
5. **Privacy gate for training images.** The preferred inputs are specimen scans and design images (no private vehicle). Where an
   in-situ photo is used, train on the **plate crop only**; images whose crop shows a private plate number are decided by the
   owner (open question 2) — PLATE-DESIGN-DATASET constraint 3 says to exclude them, and we follow that until told otherwise.

## 5. Model plan (in order; stop at the first that meets the acceptance bar)
1. **Baseline — Create ML Image Classification (Feature Print V2 transfer)**, run headlessly through the `CreateML` framework
   (`MLImageClassifier`) from a Swift script so it is reproducible and not a GUI session. Minutes to train; shows the data ceiling.
2. **Fine-tune a small CNN/ViT** (MobileNetV3-Large / EfficientNet-Lite / ViT-Tiny, ImageNet-pretrained) in PyTorch with the
   augmentation above, convert with `scripts/convert_models.py` (coremltools), 8-bit palettised for iOS/watch size. Needs
   `scripts/requirements.txt` extras; runs on the Mac (MPS).
3. **Banner assist (optional).** Crop the banner region (top ~22 % of the plate) at 4× and add it as a second input or a second head;
   the design classifier may use the banner's *shape* even when OCR cannot read it.
Licences of converted/pre-trained backbones are recorded in `models/registry.json` (`license` mandatory); weights are never committed.

## 6. Evaluation and acceptance (no claim without these)
- **Held-out real photos only.** Per-state recall, top-1/top-3, confusion matrix, and **calibration** (ECE + reliability plot).
- **Fixed regressions:** the Minneapolis crop (eval id 902, `eval/user/`, gitignored) must resolve to MN at the chosen threshold,
  and the Waltham (MA) crop must not regress; add an MN/NC/KS/WI/IA confusion check.
- **Bar to ship:** ≥ 95 % precision at ≥ 60 % coverage on the real-photo set (otherwise it abstains and we say so), and no state
  below 50 % recall hidden behind an average. A model scoring worse than "unresolved + ask the operator" is not shipped
  (same rule as MODEL-TRAINING §6).
- Record results in MODEL-TRAINING §7 with data counts, licences and the exact command; report what failed.

## 7. Integration work (after a model passes)
- `PlateKit`: `PlateStateEstimate` (distribution, model id, citation) and a fusion function in the Identity resolver, with unit tests
  for the MN/NC/KS case using a stub estimator.
- `VehicleML`: `PlateDesignStage` as an `AnalysisStage` (AGENTS.md: composable pipeline stages), registry-named model, never a path.
- Hub + iOS: show "state estimate" with confidence and the citation; Review keeps the operator in control.
- Docs: IDENTITY.md Known gap → resolved/partial with measured numbers; ROADMAP plate-design line updated only after verification.

## 8. Work packages
| # | Package | Needs | Output |
|---|---|---|---|
| P1 | Licence sign-off: read Commons licence mix from the manifest; read Kaggle page; owner decides DMV + in-situ photos | owner | updated PLATE-DESIGN-DATASET.md |
| P2 | Crawl + manifest + overlap check | owner OK to download (~1–3 GB) | `training/plate-state/` (gitignored) |
| P3 | Real-photo set from local fleet confirmations (human-checked) | Hub data on this Mac | `training/plate-state-real/` (gitignored) |
| P4 | Headless Create ML baseline + eval script | P2 | numbers in MODEL-TRAINING §7 |
| P5 | Augmentation + PyTorch fine-tune + Core ML conversion | P2–P3 | candidate model + registry entry (no weights committed) |
| P6 | Fusion + stage + UI | passing P4/P5 | PlateKit/VehicleML/Hub/iOS changes with tests |

## 9. Open questions for the owner
1. May the crawler download from Wikimedia Commons now (one request/second, descriptive User-Agent, ~1–3 GB)?
2. May in-situ photos containing private plates be used if cropped to the plate face and never stored beyond local training? (Default: no.)
3. Are state DMV design images acceptable, or only scans/CC sources?
4. Is a Kaggle account available for reading/downloading the `gpiosenka` set (human credential step), once its licence is read?
5. Do you want the fleet-confirmation labelling loop (P3) enabled, given it reuses locally confirmed Review crops for *local* training only?

## Status 2026-10-19 (end of day)
Owner approved sources (b) DMV specimens and (c) local fleet-confirmed crops. (b): no state could be confirmed usable (see PLATE-DESIGN-DATASET.md), nothing downloaded; a permission-request text is drafted there for the owner to send. (c): exporter built (`scripts/export_fleet_plate_crops.py`), 0 qualifying items today. Best baseline remains 72.1 % test on 32 states (MODEL-TRAINING §7), below the acceptance bar.
