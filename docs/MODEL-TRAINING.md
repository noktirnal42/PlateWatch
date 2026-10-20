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
   file shipped with the model) are fine. **NC / ND are never used** (the project is AGPL and
   publishes derived models). CC BY-**SA** (share-alike) is *eval-only* by default, with **one owner-approved
   exception (2026-10-13, Jeremy McVay): the plate-state classifier may train on CC BY-SA plate images**
   (`scripts/crawl_commons_plates.py --allow-sa`) because the CC0/PD/BY plate data alone is too thin
   (≈ 890 images, 12 for Minnesota). Conditions for that exception:
   - it applies **only** to the plate-state classifier — the fleet classifier and the plate detector stay on CC0/PD/BY;
   - the dataset's `ATTRIBUTION.md` (author, licence, source page per image) ships with the model and the
     model's `models/registry.json` entry says `trained on CC BY-SA 4.0 and CC BY images — see attribution`;
   - the share-alike obligations for a *model* trained on SA images are legally unsettled (is a model an
     "adaptation"?). This is a documented risk accepted by the owner, **not legal advice** — revisit before any
     public model release, and if in doubt retrain without the SA images (the manifest records each file's
     licence, so the SA files can be filtered out and the model rebuilt).

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
1. **Prepare data** (one CLI step, already scripted): `python3 -I scripts/make_plate_dataset.py training/plate-detector`
   builds `CreateML/{train,validation,test}/` from Open Images' *Vehicle registration plate* boxes —
   **built 2026-10-13: 2,167 train / 259 validation / 279 test images (2,738 / 321 / 338 boxes)**, every image
   CC BY 2.0 with an `ATTRIBUTION.md`. Each folder holds the images plus `annotations.json`: an array of
   `{ "image": <file>, "annotations": [ { "label": "plate", "coordinates": { "x", "y", "width", "height" } } ] }`
   where **x, y are the box *centre* and all four values are in *pixels***.
   **⚠ Key names:** Apple's WWDC slides use `image` / `annotations`; an Apple DTS forum answer says
   `imagefilename` / `annotation`. **Verify on import** (step 3 below). If Create ML reports 0 annotations or an
   error, run the script again with `--keys dts` (writes `CreateML-dts/`).
2. *File → New Project → Object Detection → Next*, name it.
3. On the **Data** tab set Training Data = `train`, Validation Data = `validation`, Testing Data = `test`.
   Create ML shows the parsed image/annotation counts — they must match the numbers above.
4. **Algorithm — two different options, not one:**
   *Transfer Learning* (reuses an OS backbone, trains only the head; ~5× smaller model; best for
   small data) vs *Full Network* (YOLOv2-based, trains everything; Apple suggests >200 boxes/class;
   the default). With 2.7k boxes start with **Full Network**. Turn on augmentation (exposure, blur, crop). Train.
5. Read **Precision/Recall** on the Evaluation tab; drag unseen photos (the Waltham and Minneapolis photos in
   `eval/user/`) onto **Preview** to see misses.
6. **Export** the `.mlmodel`/`.mlpackage` — **one file runs on both macOS and iOS** (choose the minimum OS at export).
   Put it in `models/cache/` and run the harness (`EvalHarness eval --models models/cache --tasks plate-detection`).
   Keep it only if it beats the YOLOv8n baseline on the **same** corpus (plate-read count today: 17/62 images).
7. Record the licence in `models/registry.json`: `"Trained in Create ML on Open Images V7 (CC BY 2.0 images)"`
   and ship the attribution file with the model.

**Where the model runs.** The iPhone app and the macOS Hub both load models by registry name through
`ModelManager`. Today **neither has a released model**: the app runs baseline Vision, and the Hub passes
`AnalysisContext(models: [:])` (HubController.swift lines 259/341/554). The Mac eval harness is the only place the
CoreML detectors currently run — which is why it finds plates the phone does not.

### 4b. Fleet classifier — *Image Classification* project
1. Folders `police/ fire/ ems/ transit/ public/ civilian/` from the **training** crawl (not
   `eval/corpus/`). Aim for ≥ 150 per class; include look-alikes (taxis, tow trucks, delivery vans,
   private security cars) in `civilian/` — they are what produces false positives.
2. *New Project → Image Classification*, drag the class folders in, train with default augmentation,
   read the **confusion matrix**.
3. Wire it as a *second opinion* alongside `VehicleCueClassifier` (labels map to `VehicleClass`).
   **Guardrail:** it only ever contributes evidence (≤ 0.45); it never lowers the 0.55 bar.
   Precision must stay 100 % with 0 civilian/commercial false positives on the eval corpus.

### 4c. Make/model, colour, plate design (state)
**Plate state is the first one needed:** Apple Vision cannot read small cursive state banners ("Minnesota" on a squad plate was unreadable at every scale/contrast tried — `docs/IDENTITY.md`). `scripts/crawl_commons_plates.py` collects CC0/PD/CC BY plate images per state (`training/plate-state/<State>/`) for an *Image Classification* project, one class per state; test it on real photo plate crops, not only on the flat scans it trains on.
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

## 7. Training log (Create ML, GUI) — 2026-10-13

Short runs first; long runs (16,000 iterations ≈ 6.5 h for the detector) only after every model works end to end.

### Plate detector — Object Detection, Full Network, 2,000 iterations (~48 min)
Data: Open Images V7 plate boxes, 2,167 / 259 / 279 images (CC BY 2.0). Create ML test set: precision 81 %, recall ≈ 67 %
(230 found, 111 missed, 55 false alarms). **Eval-harness corpus (62 images): plate reads 19/62 vs 17/62 for YOLOv8n and 12/62
with no detector; fleet recall 63 % vs 61 %; precision 100 %, 0 civilian false positives.** Finds both US police plates in `eval/user/`.
The training photos are mostly UK (double-decker buses, UK plates), yet plate *shape* transferred to US plates. Loads in
`CoreMLDetectorStage` unchanged (`VNRecognizedObjectObservation`); `EvalHarness --plate-model <file>` compares any model.
Not yet registered or bundled: neither the app nor the Hub runs a CoreML model today.

### Fleet classifier — Image Classification, Feature Print V1 → V2, 25 iterations (minutes)
| run | data | split | test acc | your photos (Waltham / Minneapolis) |
|---|---|---|---|---|
| v1 | 1,331 train, raw crawl | random | 70 % | ems 55 % / transit 52 % |
| v2 | 537 train, cleaned (Apple classifier filter) | random | 82 % | transit 97 % / transit 94 % |
| v2g | 541 train, cleaned | **by photographer** | 71 % | public 81 % / transit 74 % |
| v2g again | same | by photographer | 73 % (police 4/8) | transit 100 % / civilian 99 % |
| **crops v3** | **1,438 train crops from a 5× larger crawl** (police 349 crops, was 71), cleaned, vehicle crops | by photographer | **77 %** (139/180; police 26/35, fire 26/37, ems 25/31, transit 41/45) | **Minneapolis crop: police 100 %; Waltham crop: transit 98 %, police 2 %** |

Lessons: (1) the raw `police` class was mostly noise (~6 of 30 sampled were police cars; the rest motorcycles, bicycle patrols,
boats, vintage photos) — filter crawls with `VNClassifyImageRequest` (keep car/truck, drop motorcycle/bicycle/boat). (2) A random
split leaks near-duplicates (one Akron photographer supplies 65 images): **split by author** (`make_classifier_dataset.py
--group-by-author`); the honest score is ≈ 71–73 %, not 82 %. (3) Training data is front/side views of white-and-black
cruisers; the owner's photos are **rear views of dark SUVs** and are confidently misclassified. **Not safe as evidence — do not
wire in** until it has rear-view police data. It is not needed for the two reference photos (text + official plate identify them).

### Plate-state classifier — see the dataset notes in §4c; results appended below when trained.

**2026-10-18:** not started — no crawl has been run and the licence gate in PLATE-DESIGN-DATASET.md is still open. Blockers and the acceptance test (Minneapolis crop, MN/NC/KS confusion) are written up under "Known gap" in IDENTITY.md.

**2026-10-19 — first baseline (headless Create ML; NOT usable, not registered, no weights committed).**
Crawl (owner-approved 2026-10-19, `scripts/crawl_commons_plates.py --cap 100 --allow-sa`): 1,997 Commons files, licences CC BY-SA 4.0 ×869, PD ×357, CC BY-SA 3.0 ×212, CC0 ×202, CC BY 2.0 ×129, CC BY-SA 2.0 ×92, CC BY 4.0 ×82, CC BY 3.0 ×34; manifest with source page/licence/author in `training/plate-state/manifest.json` (gitignored). Dataset: `make_classifier_dataset.py --min 12 --val 0.15 --test 0.15 --group-by-author` → 43 classes, 1,350 / 278 / 263 train/validation/test (8 states dropped for < 12 images: ID, IA, KY, ME, NH, ND, WV, WY). `scripts/check_training_overlap.py`: 1,891 images vs 62 eval titles / 64 names / 59 hashes — no overlap. Training: `scripts/train_plate_state.swift` (Scene Print v2 + logistic regressor, 25 iterations, augmentation crop/blur/exposure/noise/rotation).
**Result: train 98.4 %, validation 61.4 %, test 62.7 %** (263 images, 43 states) — heavy overfit. Per-class test recall: **Minnesota 0 %**, Arizona 0 %, Nebraska 0 %, Massachusetts 36 %; Montana, New Mexico, Oklahoma, Rhode Island, Tennessee, Vermont 100 % (tiny test sets). This does **not** meet the spec's bar (≥ 95 % precision at ≥ 60 % coverage on real photos) and the Minneapolis acceptance crop was not run. Why it is weak, and what to change next: the Commons files are whole photos/scans, not plate crops (the classifier must be fed detector crops); many classes have < 40 training images; only flat scans and Commons photos, no real-photo set (spec P3) yet. Next: crop with the plate detector, add the 8 missing states, add augmentation by downscaling, then re-measure on real photos.

**2026-10-19 — second baseline, plate-detector crops (`scripts/plate_crops.swift`, `plate-detector-createml-v1`).** 731 images cropped to the detected plate, 977 plate-shaped scans kept whole, 255 skipped (no plate found and not plate-shaped). After the ≥ 12-images-per-class filter only **32 states** remain (19 dropped, mostly < 10 crops each) → 854 / 169 / 155 train/validation/test. **Train 98.9 %, validation 71.6 %, test 68.8 %** (155 images, 32 states); Minnesota recall 50 % and Massachusetts 75 % but on 2–8 test images each, so neither is a measurement. Different class set from the first run, so the numbers are not directly comparable. Conclusion: cropping helps the design signal, but **data volume is the binding constraint** (many states have < 10 clean plate crops). Still below the acceptance bar; still no real-photo set; nothing registered or wired in. Next: widen the crawl beyond one subcategory level and per-state "plate" search terms, add DMV/state-agency specimen images only after the owner decides (open question 3), and build the local fleet-confirmation set (P3).

**2026-10-19 — widening the Commons crawl does not help.** `crawl_commons_plates.py` gained `--depth N` (breadth-first subcategories). A re-run with `--depth 3 --cap 250` found the **same candidate counts per state** as depth 1 (e.g. Alabama 44, Alaska 13, Arizona 20, Arkansas 35), so the Commons "License plates of …" tree is exhausted at about **2,000 usable files** under the licence/year/title filters; I stopped it. More data has to come from somewhere else, and each option needs an owner decision: (a) Openverse/Flickr CC photo search (most in-situ photos show private plate numbers — spec open question 2), (b) state DMV specimen images (question 3), (c) the local fleet-confirmation set (question 5), (d) synthetic compositing from the clean scans (no decision needed, helps only with variation). Not started.

**2026-10-19 — third baseline: synthetic degradation of the train split only (option d; `scripts/augment_plate_dataset.py`, 5 copies per image: 40–160 px down-scale, perspective, blur, brightness/contrast/colour cast, noise, JPEG 30–90).** Same 32 states and the same untouched validation/test as the crop run. 5,448 train images (1,178 originals + 4,270 synthetic). **Train 86.6 %, validation 71.0 %, test 72.1 %** (155 images) — overfitting drops (98.9 → 86.6 train) and test improves 68.8 → 72.1, Minnesota 50 % (few images), Massachusetts 87.5 %. Still below the ≥ 95 % precision at ≥ 60 % coverage bar, still no real-photo evaluation, nothing registered or wired in. Synthetic variation is worth keeping; it does not replace more real designs per state.

**2026-10-20 — fourth run: + agency (DMV/DOT) images, collected by the agent through the owner's connected browser (counsel's fair-use determination, DECISIONS.md 2026-10-19).** 8 images from 6 states were gathered with their page URL and date in `training/plate-state-dmv/sources.csv` (gitignored): Alaska ×2 (Standard Gold, Grizzly Bear), Idaho ×2 (2025 sample, 2026 standard), North Dakota ×1, Rhode Island ×1 (Ocean passenger), Hawaii ×1 (Honolulu city graphic — an illustration), Mississippi ×1 (2024 standard). They were plate-cropped, expanded ×20 with `augment_plate_dataset.py` (train split only) and added as six new classes → 38 classes trained. **Test accuracy on the unchanged 155-image / 32-class test set: 72.7 % (was 72.1 %)** — no harm, but the six new states have **no test images, so nothing is known about how well they are recognised**. Not collected (page showed no standard-plate image, bot protection, or not found): Arizona, Connecticut, Delaware, Iowa, Kentucky (only a collage of specialty plates), Maine (image blocked to non-browser clients, browser download not saved), Montana, New Hampshire, New Mexico, South Carolina, Vermont, West Virginia, Wyoming. Image files are fetched with `curl` from the agency image host after the browser located the URL; some image hosts allow this although their pages return 403 (no bot-protection bypass was attempted).

### Reproducing the fleet crop dataset (one command)
`scripts/build_fleet_crop_dataset.sh <crawl dir> <out dir> [models dir]` runs the whole recipe from the lessons above: tag with Apple's
classifier and keep car/truck/bus-like images → cut the main vehicle with the vehicle detector → split **by photographer**
(`make_classifier_dataset.py --group-by-author`). On the first crawl (1,635 tagged images) it keeps 675 and yields 457/57/56
train/validation/test crops in ~35 s. Output is a Create ML Image Classification folder; train it in the GUI as in §4b.

### Fleet crop classifier, run v3 (2026-10-14): more data did what settings could not
Same recipe, 5× the data (`scripts/build_fleet_crop_dataset.sh training/fleet2 …`: 4,128 tagged images → 1,986 kept → 1,438/182/180
train/validation/test vehicle crops; police 279/35/35, public only 61/8/8). Create ML, Feature Print V2, all augmentations, 17 iterations:
**training 81 %, validation 85 %, test 77 %** (previous best 73 %); police recall 26/35 = 74 % (was 4/8), 6 false positives.
Weak spots: `fire` recall 26/37 (8 called `ems`), `ems` precision (16 false positives), `public` has too few crops (61) to judge.
**Real photos:** the Minneapolis rear crop is now **police 100 %**, but the Waltham stealth-livery rear crop (dark grey lettering on black)
is still **transit 98 %** — confident and wrong. Still **not safe to wire in as evidence** (a confident miss is worse than none); what it
shows is that the bottleneck was data volume/diversity, and that dark low-contrast liveries still need their own examples (the Hub's
text path and the review queue remain the primary route for them). Next: add stealth-livery and rear-view police images (Commons
categories are thin on them), re-measure, and keep Waltham/Minneapolis as the fixed held-out check.
