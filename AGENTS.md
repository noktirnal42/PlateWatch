# AGENTS.md — instructions for AI agents working in this repo

## What this project is

OpenALPR Platform ("PlateWatch") — an open-source ALPR system focused on
government / taxpayer-funded vehicle accountability. Swift-first
(macOS/iOS/watchOS, Xcode 27 / Swift 6.4), CloudKit backend (free tier),
Vapor reference server for cross-platform expansion.

## Guardrails — follow these strictly

1. **Fleet-focused data only.** New ingestion or enrichment code must respect
   the redaction/moderation rules in `docs/LEGAL-ETHICS.md`. Do not add code
   paths that persist un-redacted private-citizen plates or DMV-derived PII.
2. **Provenance everywhere.** Any model or code that enriches a record
   (officer, agency, cost) must write a `SourceCitation`. No unsourced
   enrichment.
3. **On-device first.** Do not add telemetry, analytics SDKs, frame uploads,
   or third-party trackers. The sync boundary is `PlateSync`.
4. **No secrets in the repo.** `.gitignore` covers the usual Apple/CloudKit
   material; extend it if you add config formats.
5. **Licenses matter.** Converted third-party ML models keep their upstream
   licenses; record them in `models/registry.json` (`license` field). Do not
   commit model weights.

## Build & test commands

```bash
swift build --package-path packages/PlateKit
swift test  --package-path packages/PlateKit
swift build --package-path packages/PlateSync
swift build --package-path server           # Vapor reference server
(cd apps/ios && xcodegen)                   # regenerate app projects
```

CI matrix source of truth: `.github/workflows/ci.yml`.

## Conventions

- Swift 6 strict concurrency; `Sendable` value types preferred over classes.
- SwiftUI for all UI; SwiftData only inside `PlateSync` local cache.
- CoreML models are referenced by registry name — never hardcode file paths.
- Package dependency direction: `PlateKit ← CaptureKit/VehicleML ← PlateSync`.
  No cycles. Apps depend on packages, packages never depend on apps.
- Server DTOs in `server/Sources/App/DTO` must stay field-compatible with
  `PlateKit`'s `*DTO` types (they are the cross-platform protocol).
- Documentation lives in `docs/`; update the relevant doc when you change
  behavior described there (especially DATA-MODEL.md and LEGAL-ETHICS.md).

## When adding features

- Prefer composable pipeline stages (`AnalysisStage` protocol in VehicleML)
  over monolithic changes.
- Every new detection class needs a confidence type and a moderation story.
- Update `docs/ROADMAP.md` checkbox state if you complete a milestone.
