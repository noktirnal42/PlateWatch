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
IDs ("NEWYORK", "COMPANY7", "0325775"), and stills now also detect plate-shaped rectangles and
read each crop separately. Every plate read now looks like a real registration (e.g. `K398HN`,
`JL923`, `PZ3122G`, `GV4728R`), but only **9–11 of 62 images** produce one. Plates are small,
angled and often blurred; the real fix is the dedicated CoreML plate detector + OCR (ROADMAP M2),
which is not shipped yet. Vision's own confidence is ~100 % on almost everything, so the displayed
plate confidence is not meaningful yet.

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
