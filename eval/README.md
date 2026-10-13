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
