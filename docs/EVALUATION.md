# Evaluation — real-world accuracy

**Date:** 2026-10-13 · **Corpus:** 62 curated US vehicle photos from Wikimedia Commons
(licensed; see `eval/manifest.json`) · **Path under test:** the same decode →
`PlateAnalysisPipeline` → markings → `RedactionGate` code the app runs, on Apple Vision
only (no PlateWatch CoreML models installed).

| Class | Images | Flagged as fleet (automatic) |
|---|---|---|
| Police | 13 | 8 |
| Sheriff / state patrol | 8 | 4 |
| Fire | 7 | 5 |
| EMS | 5 | 4 |
| Transit / school bus | 6 | 2 |
| Public service (USPS, public works, park ranger) | 7 | 3 |
| Civilian | 11 | **0** |
| Commercial (NYC taxis) | 3 | **0** |
| Unmarked police sedans (hard) | 2 | 0 |

| Metric (standard-difficulty images) | Mac | iPhone 16 Pro Max |
|---|---|---|
| Fleet **precision** | **100 %** (26 / 26) | **100 %** (27 / 27) |
| Civilian + commercial wrongly flagged | **0 / 14** | **0 / 14** |
| Fleet **recall**, fully automatic | **57 %** (26 / 46) | **59 %** (27 / 46) |
| Recall incl. **human confirmation** (review queue) | 76 % (35 / 46) | 72 % |
| Civilian vehicles in the review queue | **0** | 0 |
| Images with a plausible plate read | 9 / 62 | 11 / 62 |
| Time per still | 0.51 s | 0.77 s avg, 1.15 s max |

The same 62 images were run on a physical iPhone 16 Pro Max through the app's DEBUG
self-test; it agreed with the Mac harness on 59 of 60 scored images (the Neural Engine's
float math differs very slightly).

**History (same corpus):** text-only baseline 4 % recall → + Apple classifier cue 24 % → fix
brand-word "plates" 46 % → tiled OCR 50 % → smarter cue assignment 57 %, with 100 % precision
and 0 civilian false positives at every step.

## Plate reading — the honest answer

Plate OCR is the **weakest** part. A plausibility filter (5–8 characters, letters *and* digits, no
run of 5+ letters) removed false "plates" that were really state names, slogans and fleet asset
IDs ("NEWYORK", "COMPANY7", "0325775"), and stills also detect plate-shaped rectangles and read
each crop separately. The dedicated CoreML plate detector (home-trained on Open Images plate
boxes — see `docs/DECISIONS.md`) raised images with a plausible plate read from 12/62 to
**19/62**, and every read now looks like a real registration (e.g. `K398HN`, `JL923`, `PZ3122G`,
`GV4728R`, `POLICE D756`). Plates are small, angled and often blurred; specialized plate OCR
(ROADMAP M2) is the next lever. Vision's own confidence is ~100 % on almost everything, so the
displayed plate confidence is not meaningful yet.

## How the decision is made

`fleetConfidence` (0–1) adds up evidence; the gate persists at **≥ 0.55**:

| Evidence | Weight |
|---|---|
| Apple Vision classifier cue (`police_car`, `firetruck`, `ambulance`; `bus` × 0.6) | 0.45 × confidence |
| Service word on the vehicle (POLICE, FIRE, SHERIFF, EMS, …) | 0.32 |
| …plus an agency line saying more than the service word | +0.15 |
| …plus a unit number | +0.10 |
| Known unit in a public roster / exempt plate design | +0.20 / +0.15 |

Between **0.15 and 0.55** with real fleet evidence the detection is offered to the user
as a **review candidate**. Confirming it queues it at the 0.55 floor, which the server
files as `pending` moderation — never public on the user's word alone. A civilian vehicle
cannot reach 0.55 on a cue alone (max 0.45), and none reached the review band in this corpus.

## Known limits (be honest about these)

- **Recall is the weak side.** Stylized lettering, motion, distance and glare defeat
  Vision OCR. Unmarked cruisers are undetectable by design. A fleet-specific CoreML
  detector (ROADMAP M2) is the real fix.
- **The classifier cue is image-level.** It never attaches a bystander's plate to a fleet
  record: a cue-only vehicle carries no plates, and an existing vehicle takes the cue only
  when it is the frame's single candidate.
- **Plates must look like plates** (5–8 chars, letters and digits). All-letter vanity plates and
  all-digit plates are missed until the plate detector ships.
- **Plate accuracy is not scored yet** (no ground-truth plate labels in the corpus).
- 62 images is a smoke test, not a benchmark; numbers will move as the corpus grows.
- This is a still-photo evaluation. The live camera path (orientation, exposure) is
  covered by unit tests and a physical-device run of the app, but not scored here.

## Update — identity, official plates, tiling (2026-10-13 evening)
Fleet scoring is unchanged in kind but improved: **61 % automatic recall on the Mac and 63 % on an iPhone 16 Pro
Max, 100 % precision, 0 of 14 civilian/commercial false positives.** New: agency identity inference and its own
scoring — see [IDENTITY.md](IDENTITY.md). The harness takes `--models <dir> --tasks plate-detection` (the CoreML plate
detector lifts plate reads from 10 to 15 images without touching fleet recall), prints the identity per image, and scores
hand-labelled agencies and plates (`agency` / `plates` keys in the manifest).


## Why fleet vehicles are missed at full resolution (2026-10-13, 62-image corpus, Create ML plate detector)
29/46 fleet vehicles pass the gate; **17 do not**. Reading the failures (not tuning to them):

| Reason | Count | Examples |
|---|---|---|
| **No lettering read at all** | 10 marked + 2 unmarked | Stylised/italic or small lettering (US Mint "POLICE" reads as "POLBE"; Michigan State Police decal only; small "OKLAHOMA HIGHWAY PATROL" on a door), motion blur (fire SUVs), logo-only vehicles (USPS trucks with the eagle, no words), a bus with faint "Metro Transit". Two images are **unmarked police vehicles — undetectable from text by design** (and rightly: see LEGAL-ETHICS) |
| **Text read, below the 0.55 gate (review queue)** | 7 | STATE TROOPER 0.32/0.51, HIGHWAY PATROL 0.47, USPS "www.usps.com" 0.47, POLICE 0.46 |

- "Recall incl. review" is 76 %: the review queue catches most partial reads; an unattended Hub has no human to confirm them.
- **De-slanting italic lettering does not help** (tried shear −0.5…+0.5 on the US Mint image: every angle garbles the text; the plain read is the best). Dropped.
- What would move recall: a recogniser trained on stylised vehicle lettering (Create ML has no OCR template — needs a CLI-trained model), more tolerant fuzzy matching for state-agency phrases, and appearance cues (the vehicle-crop classifier, MODEL-TRAINING §7) for vehicles with no readable text.
- Caveat: 62 images; do not tune the gate to these failures.

## 2026-10-15: missed vehicle in wide Arlington camera view

The owner identified the white SUV at the right of a supplied Arlington airport
screenshot as the missed police vehicle. A local holdout extracted only the camera
viewport from that screenshot; the screenshot and model remain outside Git.
The ordinary installed vehicle detector returned one box on the extracted viewport.
The bounded detail stage returned five boxes, including one covering the SUV's
known center (top-left normalized 0.80, 0.72). One warm detail call took 0.034 s on
this Mac. This is a coverage regression check on a dimmed screenshot, not a general
recall benchmark, proof of police classification, or a sustained CPU measurement.

`CameraDetailDetectorStage` keeps the whole-frame detection and adds four overlapping
60% views only for thorough fixed-camera inputs at least 960 pixels on the long side.
It uses the existing installed model and unchanged 0.25 threshold. Crop results are
projected to the full frame; internal-edge truncations are rejected and overlapping
boxes are suppressed across labels. Local/handheld inputs retain the single pass.
The existing fleet scoring, plate permission, moderation and evidence redaction paths
remain downstream. A generic car box cannot establish government ownership.

All 31 VehicleML tests passed with the local holdout enabled. Offline runs skip that
one test unless `PLATEWATCH_DETAIL_IMAGE` points to the locally extracted Arlington
viewport and `PLATEWATCH_DETAIL_MODEL` points to the installed compiled detector.
Projection, duplicate-class suppression and neighboring-vehicle preservation have
ordinary offline tests. Broader labeled public-camera evaluation remains required;
the historical 62-photo precision/recall numbers above are not new measurements.

### Fixed-camera benchmark and semantic label correction

Native Nevada QA exposed non-vehicle COCO outputs (including traffic lights) being
mapped to unknown vehicles. Vehicle-task detector output now accepts road-vehicle
and explicit fleet labels only; plate-task detection is unaffected. Generic car,
bus and truck labels still cannot establish public ownership. Explicit police/fire
vehicle labels map to their fleet classes. This is covered by a semantic-label test.

The new `--camera-benchmark` mode compares whole/detail boxes and optional fleet-gate
coverage with one-to-one IoU matching. Partial labels deliberately omit precision
and false positives. The owner-reported Arlington SUV annotation is partial: the
local run measured whole-frame target misses=1, detail target misses=0, and fleet-gate
target misses=1. That last result is a real remaining classification gap, not a failed
box test to hide. No image or private plate data was committed. See eval/README.md.
All 36 VehicleML tests passed with the screenshot holdout enabled; the release
harness built and ran against the installed detector. Broader annotated camera
coverage and a validated fleet classifier remain open.

## Generic body classes in Live

CoreML's car/truck/bus/motorcycle labels are preserved in `VehicleAttributes.bodyType`,
separate from `VehicleClass` (fleet identity). Text inference can still supply a fleet class
without erasing the generic body label. The Hub displays ordinary body classes without a
misleading zero fleet score. This is coarse detection output, not a new trained make/model
classifier or fleet claim. 37 VehicleML tests pass, including the new label-preservation
contract; the local-image holdout remains a separate opt-in. Native Austin Live showed
Car and Truck labels. Model misclassification/missed vehicles remain evaluation work.
