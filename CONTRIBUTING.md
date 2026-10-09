# Contributing

Thanks for helping build accountable, transparent public infrastructure.

## Ground rules

This project exists to catalog **publicly funded vehicles and agencies** using
publicly observable data and public records. Contributions that broaden the
project into general-purpose tracking of private individuals will not be
accepted. Read [docs/LEGAL-ETHICS.md](docs/LEGAL-ETHICS.md) before writing
ingestion, enrichment, or publishing code.

## Development setup

- Xcode 27+, Swift 6.4, macOS 15+ for development
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen) for app projects
  (`brew install xcodegen`)
- Python 3.12+ only for `scripts/` (use `scripts/.venv`, nothing global)

## Workflow

1. Fork, branch from `main`: `feat/<thing>` or `fix/<thing>`.
2. `swift test --package-path packages/<touched package>` must pass.
3. If you touch DTOs, check them against `server/` models and
   `docs/DATA-MODEL.md` — the REST protocol and CloudKit schema must stay
   in lockstep.
4. PRs: describe the change, the privacy impact, and the test plan.
   CI must be green.

## Adding ML models

Models are produced by `scripts/convert_models.py` from upstream open
projects and registered in `models/registry.json` with: name, task,
source URL, upstream license, sha256, input contract. Never commit weights;
contributors run the conversion script locally (CI verifies the *conversion*,
not the accuracy).

## Code style

- Swift 6 concurrency-correct (`Sendable`, actors where state is shared).
- No force-unwraps in library code; structured errors via typed `Error`s.
- Public API documented with doc comments; non-obvious ML thresholds get an
  inline comment citing why the value was chosen.

## Data contributions

Public-records datasets (fleet lists, rosters) are contributed as import
specs under `server/Resources/Importers/` with a source URL and retrieval
date. No scraped PII from non-official sources.
