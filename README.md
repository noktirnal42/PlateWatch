# PlateWatch

**Open-source Automatic License Plate Recognition for public accountability.**
Turning the tables on mass surveillance: a community platform for identifying,
cataloging, and sharing information about taxpayer-funded vehicles — police,
fire, public works, transit, and government fleets — using commodity cameras
and on-device machine learning.

> Built Swift-first for macOS / iOS / watchOS on Xcode 27 (Swift 6.4),
> with a portable REST protocol and reference server so every platform can
> join later. Core ML runs on Apple Neural Engine; no frame ever has to
> leave the device.

---

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

# 4. Enable the CloudKit capability (container iCloud.org.platewatch),
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

## License

AGPL-3.0 — see [LICENSE-AGPL-3.0.txt](LICENSE-AGPL-3.0.txt). Contributions
welcome; see [CONTRIBUTING.md](CONTRIBUTING.md).
