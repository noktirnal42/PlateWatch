# PlateWatch

**Open accountability infrastructure: on-device recognition of publicly funded
fleets, plus cited public records (rosters, FOIA releases, Brady lists, court
dockets) that connect vehicles to the officials who run them.**
Turning the tables on mass surveillance: a community platform for identifying,
cataloging, and sharing information about taxpayer-funded vehicles — police,
fire, public works, transit, and government fleets — using commodity cameras
and on-device machine learning.

> Built Swift-first for macOS / iOS / watchOS on Xcode 27 (Swift 6.4),
> with a portable REST protocol and reference server so every platform can
> join later. Core ML runs on Apple Neural Engine; no frame ever has to
> leave the device.

---

## Project status — pre-alpha

The core loop now works on real photos: **point it at (or import a photo of) a public-service
vehicle and it recognises it, reads door text and plates, and records it** — with a human
confirm step for borderline cases. Measured on 62 real US photos
([docs/EVALUATION.md](docs/EVALUATION.md)): **100 % precision, 0 civilian false positives,
57 % fully-automatic recall (76 % with confirmation)** on Apple Vision alone, identical on a
physical iPhone. Recall is the weak side and is the main thing still to improve.

| Area | State |
|---|---|
| Core packages (PlateKit, CaptureKit, VehicleML, PlateSync, FleetImporters) | Built and tested — 155 tests pass |
| iOS app | Builds, installs and runs on simulator and iPhone; photo-import → recognise → record works; live camera path unit-tested but not yet field-verified |
| Reference server (ingest, moderation, exports, k-anonymous heatmap, agency report) | Builds, 41 tests pass; not deployed publicly |
| CloudKit public database | Backend + schema written ([cloudkit/](cloudkit/)); **awaiting import/deploy with the developer account** |
| CoreML models | Optional; not yet published. Apple's built-in vehicle classifier is used instead for now |
| watchOS app / macOS Hub / CarPlay | Present; not verified in the latest pass (CarPlay needs Apple's entitlement) |

Known problems and what was fixed: [docs/QA-REPORT.md](docs/QA-REPORT.md). Plan:
**M-Alpha** in [docs/ROADMAP.md](docs/ROADMAP.md). Contributions welcome.

## What it does

| Stage | Tech | Runs where |
|---|---|---|
| Vehicle detection | CoreML object detector (YOLO family) | On-device (ANE) |
| Vehicle attributes (make/model/color/type, light bars, decals) | CoreML classifiers + Vision feature prints | On-device |
| Plate detection | CoreML plate detector (converted from open ONNX/YOLO models) | On-device |
| Plate OCR | Apple Vision `VNRecognizeTextRequest` baseline; specialized plate-OCR CoreML model when downloaded | On-device |
| Fleet/Agency parse (door text → agency, unit number) | Vision text + Apple FoundationModels structured extraction (iOS/macOS 26+) | On-device |
| Enrichment (unit # → agency roster, public records) | Public-records connectors + moderation queue | Backend |
| Shared database | **CloudKit public database (free tier)** | All Apple devices |
| Cross-platform sync | Reference Vapor REST server (AGPL), free-tier-hostable | Any platform |

## Mission rules (non-negotiable, encoded in the data layer)

1. **Government / fleet focus.** The platform exists to track *publicly funded
   assets*. Private-citizen plates are redacted by default on ingest unless a
   fleet-confidence threshold is met. See [docs/LEGAL-ETHICS.md](docs/LEGAL-ETHICS.md).
2. **Public records only.** Officer/agency enrichment comes exclusively from
   public sources (fleet registries, FOIA releases, rosters, auction listings)
   with a stored citation per field. Never DMV data (DPPA).
3. **Evidence quality.** Every sighting is content-hashed (SHA-256) and
   timestamped; sources carry provenance.
4. **On-device first.** Raw video never leaves the device. Only structured,
   human-reviewable detections sync.

## Repository layout

```
apps/            iOS app, macOS "Hub" app, watchOS companion (xcodegen projects)
packages/
  PlateKit/      Domain model + plate normalization/validation (pure Swift)
  CaptureKit/    AVFoundation + Vision capture & analysis pipeline
  VehicleML/     CoreML model registry, detectors, re-ID, OCR engines
  PlateSync/     Sync abstraction + CloudKit backend + REST client + outbox
server/          Optional self-hosted mirror (Vapor + Postgres) for non-Apple platforms
docs/            Research, hardware guide, architecture, data model, legal/ethics, roadmap
models/          Model registry manifest (weights are downloaded, never committed)
scripts/         coremltools conversion pipeline (.venv, never outside workspace)
.github/         CI
```

## Quick start

```bash
# 1. Verify the core packages build and test
swift build --package-path packages/PlateKit && swift test --package-path packages/PlateKit

# 2. (Optional) convert the recommended open models to CoreML
python3 -m venv scripts/.venv && scripts/.venv/bin/pip install -r scripts/requirements.txt
scripts/.venv/bin/python scripts/convert_models.py --all

# 3. Generate the app projects (requires xcodegen)
(cd apps/ios && xcodegen) && (cd apps/macos-hub && xcodegen) && (cd apps/watchos && xcodegen)
open apps/ios/PlateWatch.xcodeproj

# 4. Enable the CloudKit capability (container iCloud.org.platewatch.platewatch),
#    build, run.
```

## Documentation

- [docs/RESEARCH.md](docs/RESEARCH.md) — existing projects to port, CoreML model survey, camera research summary
- [docs/HARDWARE.md](docs/HARDWARE.md) — camera hardware guide (phones → PoE → dedicated ALPR)
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — system design
- [docs/DATA-MODEL.md](docs/DATA-MODEL.md) — schema (CloudKit record types + SQL mirror)
- [docs/BACKEND.md](docs/BACKEND.md) — CloudKit-first backend, free-tier self-host options
- [docs/LEGAL-ETHICS.md](docs/LEGAL-ETHICS.md) — the guardrails that keep this lawful and safe
- [docs/ROADMAP.md](docs/ROADMAP.md) — milestones and feature backlog
- [docs/QA-REPORT.md](docs/QA-REPORT.md) — latest QA findings, ranked by severity, with resolution status
- [docs/NEXT-STEPS.md](docs/NEXT-STEPS.md) — what is not done yet and how to do it (start here)
- [docs/EVALUATION.md](docs/EVALUATION.md) — real-world accuracy on a licensed photo corpus
- [cloudkit/README.md](cloudkit/README.md) — CloudKit schema and one-time setup
- [docs/DECISIONS.md](docs/DECISIONS.md) — decision log for model and design choices
- [docs/FOIA.md](docs/FOIA.md) — requesting fleet records from agencies
- [docs/PLATE-DESIGN-DATASET.md](docs/PLATE-DESIGN-DATASET.md) — plate-design classifier dataset plan

## License

AGPL-3.0 — see [LICENSE-AGPL-3.0.txt](LICENSE-AGPL-3.0.txt). Contributions
welcome; see [CONTRIBUTING.md](CONTRIBUTING.md).
