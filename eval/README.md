# Evaluation corpus & harness

Measures the **production** analysis path (image decode → `PlateAnalysisPipeline`
→ fleet markings → `RedactionGate`) against labelled real-world US vehicle photos.
Results and methodology: [docs/EVALUATION.md](../docs/EVALUATION.md).

```bash
python3 eval/fetch_corpus.py --per-query 4        # download licensed images → eval/corpus/ (gitignored)
(cd eval/harness && swift build -c release)
eval/harness/.build/release/EvalHarness eval       # prints per-image results + scores
```

- `manifest.json` — **committed**: every image's source page, license, author, class
  and expected label. Only CC0 / public-domain / CC-BY / CC-BY-SA files are fetched
  from Wikimedia Commons; attribution is in the manifest.
- `corpus/` — **gitignored**: the images themselves (some show civilian plates).
- `results/` — **gitignored**: contact sheets and `latest.json`.
- Classes: `police`, `sheriff` (incl. state patrol), `fire`, `ems`, `transit`
  (incl. school buses), `public` (USPS, public works, park rangers), `police-unmarked`
  (hard cases), `civilian`, `commercial` (NYC taxis — licensed but privately owned,
  must **not** be flagged as government fleet).
- The labels were curated by eye from contact sheets (search results are noisy);
  non-US, historical, interior and irrelevant hits were dropped.

On-device check: a Debug build run with `-PWSelfTest` analyses images copied into
the app's `Documents/selftest/` on the device and prints results to the console.

## Labeled fixed-camera benchmark

The harness now compares whole-frame and bounded-detail geometry without plate
OCR or creating records. Images stay local. Supply a manifest with relative image
paths, complete normalized top-left boxes and an explicit annotation-completeness flag:

```json
{"frames":[{"id":"camera-case-1","image":"frame.png","exhaustive":false,
"vehicles":[{"x":0.2,"y":0.3,"width":0.1,"height":0.1}],
"fleetVehicles":[{"x":0.2,"y":0.3,"width":0.1,"height":0.1}]}]}
```

```sh
swift run -c release --package-path eval/harness EvalHarness \
  --camera-benchmark "$CAMERA_MANIFEST" --vehicle-model "$INSTALLED_VEHICLE_MODEL"
```

`--vehicle-model` accepts a local compiled model or source model explicitly supplied
by the operator; it downloads nothing. Paths cannot escape the manifest's directory.
Matching uses confidence-ordered, one-to-one IoU ≥ 0.5. Partial annotations report
coverage/misses and unmatched candidates, with **no precision/false-positive claim**.
Use `exhaustive:true` only after labeling every vehicle of the scored population.
Optional `fleetVehicles` scores the production fleet gate separately, with plate
reading disabled. A recovered car box does not become a successful fleet detection.
Output is JSON counts and timings; raw frames, plates and OCR text are not exported.
Timings are sequential and affected by model/framework warm-up; they are not a fair
cold-start comparison or a sustained performance pilot.
