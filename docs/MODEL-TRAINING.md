# MODEL-TRAINING.md — datasets (USA) and the Apple Create ML (GUI) training path

Companion to NEXT-STEPS §3 (plate reading), §5 (fleet recall), ROADMAP M2.
Scope: **USA vehicles and plates**. Every dataset lists its licence — AGENTS.md
guardrail 5 requires recording it in `models/registry.json` before a derived
model is committed or published. **Do not commit weights or training images.**

> **Revised 2026-10-13 (review pass).** First draft by GLM 5.3; claims were
> re-verified against the dataset cards / Apple material and corrected — see
> [SPEC-REVIEW.md](SPEC-REVIEW.md) for what changed and why. Anything still
> unverified is marked **⚠ unverified**.

## 0. The two rules that protect the numbers

1. **Eval images never train.** `eval/corpus/` is the *test set* (see
   EVALUATION.md). Training on it would make every reported accuracy meaningless.
   Train from a **separate** crawl (`training/…`, gitignored) and keep a filename/hash
   blocklist of every eval image so the two can never overlap.
2. **Only train on licences we can honour.** CC0 / public domain / CC BY (attribution
   file shipped with the model) are fine. CC BY-**SA** (share-alike) is *used for eval only*
   unless the owner decides a model trained on SA images is acceptable. **NC / ND are never
   used** (the project is AGPL and publishes derived models).

## 1. What Create ML can and cannot train

| Task | Create ML template | Notes |
|---|---|---|
| Plate **detector** (find plates in a frame) | **Object Detection** | Needs boxes (annotation JSON). |
| **Fleet class** (police / fire / EMS / transit / public / civilian) | **Image Classification** | Needs *hundreds* of images per class — see §3. |
| **Plate design / state** of a cropped plate | Image Classification | Crops from the plate detector. |
| Vehicle make/model, colour | Image Classification | Train on vehicle crops, not scenes. |
| **Plate OCR** (reading the characters) | ❌ **none** | Create ML has no OCR/sequence template. OCR stays on Apple Vision (+ our plausibility rules) until a CLI-trained model (PyTorch → coremltools) is justified. A "700k plates" corpus therefore cannot be used through the GUI. |

## 2. Dataset shortlist (verified 2026-10-13)

### Usable

| Dataset | What | Size | Licence | Use for | Verified notes |
|---|---|---|---|---|---|
| **Open Images V7** — class *Vehicle registration plate* (`/m/01jfm_`) | Plate boxes on Flickr photos | **⚠ unverified** count (draft said ~15k) | Annotations **CC BY 4.0**; images **CC BY 2.0 per-image** | Plate detector; also classes *Ambulance*, *Taxi*, *Van*, *Bus*, *Truck*, *Car* | Class + IDs confirmed in `oidv7-class-descriptions-boxable.csv`. Google states it does **not** guarantee each image's licence — check per image. Global, **⚠ "US-heavy" unverified**. |
| **Open Images V7 — Vehicle registration plate** (the right source) | Plate boxes on Flickr photos | validation+test: **2,775 images / 3,806 boxes** (counted 2026-10-13; train split is larger, not yet counted) | Annotations CC BY 4.0; **every one of those 2,775 photos is individually CC BY 2.0** (author + Flickr page recorded in the images CSV) | Plate detector | Mostly Western Flickr photos; build with `scripts/make_plate_dataset.py` — ready-made for Create ML, with `ATTRIBUTION.md` |

### Looks usable but is not — the "keremberke" / "justjuu" plate sets
Both Hugging Face repos are **one** dataset (8,823 images, "CC BY 4.0", Roboflow export). A filename audit
(2026-10-13) shows its provenance is **not** what the card implies: only **271 images (3 %)** have Open-Images-style
IDs (those exist in Open Images → they are CC BY 2.0 Flickr photos, not CC BY 4.0); the other **97 %** are Vietnamese
sources (`xemay…` = motorbikes, `quandoi…` = military, `ngoaigiao…` = diplomatic) and a few generic
`CarLongPlate…` families with no recorded origin. Wrong domain for US plates (motorbike and military plate shapes), unknown
image rights behind the "CC BY 4.0" tag, and military/diplomatic plates are sensitive. **Do not use for training.**

### Do not use (recorded so nobody re-evaluates)

| Dataset | Why |
|---|---|
| **mabo7237/license-plates-700k** (MIT-tagged) | The draft listed it as "recommended". Verified: card is **empty**, viewer errors, 20 GB, "Duplicated from guica/license-plates-700k", **no provenance**. An MIT tag on an unexplained scrape proves nothing — plate scrapes (e.g. PlatesMania-style sites) are rarely redistributable. Excluded until provenance is documented. |
| UniDataPro/united-states-license-plate-dataset | `cc-by-nc-nd-4.0`; the free repo is a **5-row, 1 MB preview** of a paid 73k set. NC + ND is incompatible with an AGPL app that publishes derived models. |
| UniDataPro/license-plate-detection (86 countries), UniqueData/license_plates | Same NC-ND licence / paid. |
| CCPD (China), UFPR-ALPR (Brazil), AOLP / TLPD (Taiwan), Persian/Algerian sets | Out of USA scope. |
| Stanford Cars, CompCars, VMMRdb | Research-only / unclear licence — not usable for a published model. |

### The data we actually need does not exist as a ready download
Every plate dataset above is **plates only**. Nothing found gives US **police / fire / EMS / transit /
public-works vehicles**, door lettering, or plate state/design. For those the realistic sources are:

1. **Wikimedia Commons category crawl** (extend `eval/fetch_corpus.py` with
   `generator=categorymembers` over e.g. *Police vehicles in the United States by state*, *Fire
   engines of the United States*, *Ambulances in the United States*, *School buses in the United
   States*, *Postal vehicles of the United States*) — hundreds of images per class, licence recorded per
   file, filtered to **CC0 / PD / CC BY** for training.
2. Open Images *Ambulance / Taxi / Bus / Truck / Van / Car* crops (CC BY 2.0 per image).
3. The owner's own photos (the Waltham photo is a good example — labelled, but **never** shared
   unless the owner says so).

## 3. How much data is enough (and why the current corpus is not)

| Template | Minimum to start | To get something trustworthy |
|---|---|---|
| Object Detection — *Transfer Learning* | dozens of images per class (WWDC: 30+/class, balanced) | a few hundred boxes |
| Object Detection — *Full Network* | Apple suggests **> 200 boxes per class** | thousands (the 8.8k plate set is fine) |
| Image Classification | ~10 images/class technically trains | **100–300+ per class, balanced** |

`eval/corpus/` has 5–13 images per fleet class — fine as a test set, **hopeless as training data**.
That is why §2's Commons crawl comes first.

## 4. Create ML GUI walkthrough (no heavy CLI)

Open **Create ML**: *Xcode → Open Developer Tool → Create ML* (or the standalone app).

### 4a. Plate detector — *Object Detection* project
1. **Prepare data** (one agent/CLI step, `scripts/coco_to_createml.py`): converts the COCO export
   to Create ML's format. The JSON is an array of `{ "image": <file>, "annotations": [ { "label":
   "plate", "coordinates": { "x", "y", "width", "height" } } ] }` where **x, y are the box *centre*
   and all four values are in *pixels*** (not normalised, not top-left). Put images and the JSON in
   the same folder; make a second folder for validation (~10 %).
   **⚠ Key names:** Apple's WWDC slides use `image` / `annotations`; an Apple DTS forum answer says
   `imagefilename` / `annotation`. The file name Create ML expects is `annotations.json` (the draft's
   `labels.json` is probably wrong). **Verify:** drag the folder into a new project — the app
   reports the number of images/annotations it parsed, or an error. Fix the keys if needed.
2. *File → New Project → Object Detection*, drag the training and validation folders in.
3. **Algorithm — two different options, not one:**
   *Transfer Learning* (reuses an OS backbone, trains only the head; ~5× smaller model; best for
   small data) vs *Full Network* (YOLOv2-based, trains everything; Apple suggests >200 boxes/class;
   the default). For the 8.8k-image plate set start with **Full Network**; for a few hundred boxes
   use **Transfer Learning**. Turn on augmentation (exposure, blur, crop).
4. Train; read **Precision/Recall** on the Evaluation tab; drag a few unseen photos (including the
   Waltham photo) onto **Preview** to see misses.
5. **Export** the `.mlmodel`/`.mlpackage` → `models/cache/` → run the harness
   (`EvalHarness eval --models models/cache --tasks plate-detection`). Keep it only if it beats the
   YOLOv8n baseline on the **same** corpus (plate-read count today: 15/62 images; exact-match scoring
   is being added — NEXT-STEPS §3).
6. Record the licence in `models/registry.json`: `"Trained in Create ML on <dataset> (<licence>)"`
   and ship the CC BY attribution file with the model.

### 4b. Fleet classifier — *Image Classification* project
1. Folders `police/ fire/ ems/ transit/ public/ civilian/` from the **training** crawl (not
   `eval/corpus/`). Aim for ≥ 150 per class; include look-alikes (taxis, tow trucks, delivery vans,
   private security cars) in `civilian/` — they are what produces false positives.
2. *New Project → Image Classification*, drag the class folders in, train with default augmentation,
   read the **confusion matrix**.
3. Wire it as a *second opinion* alongside `VehicleCueClassifier` (labels map to `VehicleClass`).
   **Guardrail:** it only ever contributes evidence (≤ 0.45); it never lowers the 0.55 bar.
   Precision must stay 100 % with 0 civilian/commercial false positives on the eval corpus.

### 4c. Make/model, colour, plate design
Same GUI flow on **cropped** vehicles/plates. Colour labels are cheap to add by eye on our own
images; make/model has no licence-clean US dataset yet (DECISIONS.md M2 note).

## 5. CLI steps an agent does so you don't have to
- `scripts/coco_to_createml.py` (COCO → Create ML JSON; pure Python, tested on a sample).
- Commons category crawler → `training/<class>/` with a manifest of source, licence and author.
- The overlap check that fails if any training file is also in `eval/manifest.json`.
Training itself stays in the GUI.

## 6. After training (publishing)
Per NEXT-STEPS §4: Apple Archive each model (`aa archive … -a lzfse`), sha256 the archive, update
`models/registry.json` (licence mandatory), publish a release (the owner runs `gh release create`),
and surface the model in About. Never ship a model that scores worse than the current one on the
same corpus.
