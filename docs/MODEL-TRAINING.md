# MODEL-TRAINING.md — datasets (USA) and Apple Create ML training path

Companion to NEXT-STEPS §3 (plate reading), §5 (fleet recall), ROADMAP M2.
Scope: **USA vehicles and plates**. Every dataset candidate lists its license —
AGENTS.md guardrail 5 requires recording it in `models/registry.json` before
weights or derived models are committed/published. **Do not commit weights.**

## 1. Dataset shortlist (researched 2026-10-13)

### Recommended (license-compatible)

| Dataset | What | Size | License | Use for |
|---|---|---|---|---|
| **Open Images V7** — class "Vehicle registration plate" | Plate + vehicle bboxes on Flickr photos, US-heavy | ~15k plate images | Images **CC BY 2.0**, annotations CC BY 4.0 | Plate/vehicle **detector** training; also source of make/model variety |
| **keremberke/license-plate-object-detection** (HF, mirrors Roboflow "vehicle-registration-plates-trudk") | Single-class plate detection | 8.8k (6.2k train) | CC BY 4.0 (per Roboflow) | Detector training; multi-country but plates are plates |
| **justjuu/license-plate-detection** (HF, cleaned Roboflow export) | Single-class plate detection, traffic scenes | ~10k | CC BY 4.0 | Detector training |
| **mabo7237/license-plates-700k** (HF) | Massive plate crop corpus | 700k | MIT | Plate **OCR** pretraining; verify provenance (likely PlatesMania-style scraping — spot-check images before use) |

### Excluded (recorded so nobody re-evaluates them)

| Dataset | Why excluded |
|---|---|
| UniDataPro/united-states-license-plate-dataset (73k US plates, OCR) | **CC BY-NC-ND**: non-commercial + no-derivatives — incompatible with AGPL app + publishing derived models; also paid "get the data" |
| UniDataPro/license-plate-detection (86 countries) | Same CC BY-NC-ND |
| CCPD (China), UFPR-ALPR (Brazil), AOLP (Taiwan), persian/taiwan/algerian sets | Out of USA scope |
| Stanford Cars (make/model) | Research-only license; consider Open Images "car" crops + our own labeled corpus instead |

### For make/model/color (user goal)

- No recordable-license US make/model dataset found yet — decision pending in
  `docs/DECISIONS.md` (M2 note). Practical path: **Open Images vehicle crops**
  (CC BY 2.0) hand-labeled in batches (contact-sheet curation like
  `eval/fetch_corpus.py`), or license-review of Stanford Cars for internal
  eval-only use (never published).
- **Color**: train from our own corpus — color labels are cheap to add by eye
  and the corpus is fleet-scoped (matching the product). No external dataset
  required.

## 2. Create ML GUI path (user preference: no heavy CLI)

Apple's **Create ML app** (Xcode → Open Developer Tool → Create ML) trains
CoreML models entirely in the GUI:

### Plate detector (Object Detection project)
1. Prepare a folder of images + a Create ML JSON annotation file
   (`labels.json`): `{"image":"file.jpg","annotations":[{"label":"plate",
   "coordinates":{"x":…,"y":…,"width":…,"height":…}}]}` — coordinates are the
   bbox **center** in pixels, normalized 0–1 × image size.
2. Split train/validation folders (~90/10).
3. Create ML: `File → New → Object Detection`, drag the two folders in.
4. Options: start from **Full Network** transfer-learning
   (YOLOv2-based); augmentation on (crop, exposure, blur) helps plate
   robustness; iterations 5k–20k.
5. Watch live Precision/Recall per class in the **Evaluation** tab; drag test
   images into **Preview** to eyeball misses.
6. `Export` → `.mlpackage` → drop in `models/cache/` → run the eval harness
   (`EvalHarness eval --models models/cache`) → if better than the YOLOv8n
   baseline (15/62 plate reads today), update `models/registry.json`
   (license field = "Trained in Create ML on <dataset>, license <…>").

### Fleet classifier (Image Classification project) — recall lift (NEXT-STEPS §5)
1. Folders per class: `police/`, `fire/`, `ems/`, `transit/`, `public/`,
   `civilian/` — source from `eval/corpus/` (licensed) grown via
   `eval/fetch_corpus.py` and hand-curated.
2. Create ML: `New → Image Classification`, drag folders, train (augmentations
   default), check the confusion matrix in the Evaluation tab.
3. Export → wire as a `VehicleCueClassifier` replacement/second opinion —
   PlateKit's cue plumbing accepts any labels mapped to `VehicleClass`.
4. **Guardrail (NEXT-STEPS §5):** never lower the 0.55 automatic threshold to
   gain recall — add evidence; precision must stay 100 % with 0 civilian FP.

### Make/model (Image Classification) and color (Image Classification)
Same GUI flow; classes = make/model strings or color names. Train on cropped
vehicle boxes (the pipeline already produces them) so the classifier sees
vehicles, not scenes.

## 3. One-time CLI step (agent can do)

Converting Open Images CSV annotations → the Create ML `labels.json` format
is a small script (`scripts/convert_openimages_to_createml.py`) — the only
CLI involvement; training itself stays in the GUI. TODO before first training
run.

## 4. After training (publishing)

Per NEXT-STEPS §4: AppleArchive each `.mlpackage` (`aa archive … -a lzfse`),
sha256 the archive, update `models/registry.json` (`license` field mandatory),
`gh release create models-v0.1.0 *.aar` (owner runs), and surface model state
in About. The harness decides regression-or-not — never ship a model that
scores worse than the current one on the same corpus.
