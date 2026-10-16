# AGENTS.md — instructions for AI agents working in this repo

## What this project is

PlateWatch — an open-source ALPR system focused on
government / taxpayer-funded vehicle accountability. Swift-first
(macOS/iOS/watchOS, Xcode 27 / Swift 6.4), CloudKit backend (free tier),
Vapor reference server for cross-platform expansion.

## Guardrails — follow these strictly

1. **Fleet-focused data only.** New ingestion or enrichment code must respect
   the redaction/moderation rules in `docs/LEGAL-ETHICS.md`. Do not add code
   paths that index private-citizen plates or persist DMV-derived PII. The owner-approved
   local Hub Review exception in Rule 1 preserves intact fleet-target evidence crops,
   including incidental background content. Do not reintroduce overlap-based image
   suppression or plate/text blackouts there. This exception does not authorize uploading
   Review image bytes or relaxing shared structured-data rules.
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

6. **Never commit local-data links or machine-specific paths.** No symlinks into a dev machine's folders (e.g.
   `eval/corpus -> /Volumes/...`), no absolute paths in tracked files. A tracked symlink replaces the real directory on
   checkout and **deletes the ignored data inside it** (this wiped the eval corpus and user photos on 2026-10-13). Check
   `git status` / `git diff --cached --stat` for mode `120000` before committing, and never `git add -A` blindly in a
   worktree you linked data into. Ignore data paths in `.gitignore` *without* a trailing slash so they match links too.

7. **Parallel agents use separate git worktrees.** Do not edit or run branch-changing git commands in a checkout another
   agent is using; make your own (`git worktree add /private/tmp/<name> -b <branch> origin/main`) and work only there.

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
- Package dependency direction: `PlateKit ← CaptureKit/VehicleML ← PlateSync`,
  `PlateKit ← AccountabilityKit`, `PlateKit ← FeedIngest`. No cycles. Apps
  depend on packages, packages never depend on apps.
- **Workstream-scoped work.** `docs/PROJECTS.md` is the dashboard: load ONE
  workstream section (its packages, docs, test command) per session and keep
  diffs inside it. Cross-cutting PlateKit/DTO changes = WS6; run every package's
  tests. Update your workstream's Status line at the end of the session.
- Server DTOs in `server/Sources/App/DTO` must stay field-compatible with
  `PlateKit`'s `*DTO` types (they are the cross-platform protocol).
- Documentation lives in `docs/`; update the relevant doc when you change
  behavior described there (especially DATA-MODEL.md and LEGAL-ETHICS.md).

## When adding features

- Prefer composable pipeline stages (`AnalysisStage` protocol in VehicleML)
  over monolithic changes.
- Every new detection class needs a confidence type and a moderation story.
- Update `docs/ROADMAP.md` checkbox state if you complete a milestone.
