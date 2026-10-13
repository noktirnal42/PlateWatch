# Next steps — what is NOT done, and how to do it

Written 2026-10-13 for the next agent or contributor. Read first: `AGENTS.md` (guardrails),
`docs/EVALUATION.md` (what works, measured), `docs/QA-REPORT.md` (resolution table),
`docs/LEGAL-ETHICS.md`. Every item below says **why it matters**, **how to do it**, and
**how to know it worked**.

Priority order: 1 → 2 → 3 are blockers for a real-world pilot; the rest raise quality.

---

## 1. Bring CloudKit live  *(blocked on the owner's Apple Developer account)*

**State:** `CloudKitBackend` is restructured and `cloudkit/schema.ckdb` is written, but nothing has
been imported into a real container. Unit tests only cover the plate-upload rule and record-type names.

**Why:** without it the app falls back to a REST mirror that is not deployed, so recorded sightings
sit in the outbox ("Needs attention" pill) and Explore is empty.

**Steps** (details in `cloudkit/README.md`):
1. Confirm container `iCloud.org.platewatch.platewatch` exists (Xcode creates it with the iCloud capability + automatic signing; team ID comes from the gitignored `apps/ios/project.local.yml`).
2. The owner creates a **CloudKit management token** (Dashboard → Tokens & Keys). **Never put it in the repo or paste it in chat**; the owner runs `xcrun cktool save-token --type management` themselves.
3. `xcrun cktool validate-schema` then `import-schema` against `--environment development` with `cloudkit/schema.ckdb`. Fix any syntax complaint — the file was written from the documented `.ckdb` grammar but could **not** be validated without a token.
4. Run a Debug build on a device signed into iCloud, record a sighting, confirm a `SightingSubmission` appears in Dashboard → Records (development).
5. Dashboard → Deploy Schema Changes (development → production).

**Done when:** a device-recorded sighting shows up in the Dashboard; the Sightings pill goes from "Retrying/Needs attention" to synced (the outbox drains); a second device **cannot** read the `SightingSubmission` (verify the `_creator`-only role works; if the world can read it, that is a privacy bug — stop and fix the schema).

**Known risk to verify:** `CKQuery` on `Sighting` filters `moderationState == fleetConfirmed` and sorts by `capturedAt`; both fields must be QUERYABLE/SORTABLE in the deployed schema (they are in the file). A "field not queryable" error means the schema import didn't apply.

### 1b. Build the moderator publish tool  *(not started)*
Accepted `SightingSubmission` records must be copied to world-readable `Sighting` by something that is
**not** an app client (no CREATE grant for clients). Options: (a) a small Swift CLI/Vapor job using a
CloudKit **server-to-server key**, reusing `server/Sources/App/ModeratorController.swift` logic and
`RedactionGateService` rules; (b) manual via Dashboard for the pilot. Rules to preserve: plate text only
for fleet-confirmed (≥ 0.8 with markings); never exact geo below confirmation; geohash6 only.
**Done when:** a confirmed submission appears as a `Sighting`, and Explore/`pullSightings` show it.

### 1c. (Optional) deploy the REST reference server
`server/` (Vapor + Postgres) is the working moderation path today but is not hosted. See
`docs/BACKEND.md` for env vars (`MODERATOR_TOKEN` ≥ 24 chars, `PORT`, `HOST`, `EXPORT_DIR`) and the
free-tier hosting notes (ROADMAP M5). The app reads `PLATEWATCH_MIRROR_URL` when not on CloudKit.

---

## 2. Field-test the live camera  *(needs a human holding the phone)*

**State:** orientation (`AVCaptureDevice.RotationCoordinator`), auto-exposure with a capped shutter, and
the overlay aspect-fill mapping are implemented and unit/photo tested, but **never seen on a live feed**.
iPhone Mirroring cannot expose the camera ("iPhone camera is not available from Mac"), and the
simulator has no camera.

**How:** install a Debug build on the iPhone (`xcodebuild … -destination 'id=<UDID>' -allowProvisioningUpdates`,
then `xcrun devicectl device install app`), point it at (a) a parked police/fire/transit vehicle in daylight,
(b) dusk, (c) a moving vehicle from a passenger seat, in portrait **and** landscape.

**Check:** the overlay boxes sit on the vehicle (not offset/rotated); text/plates read in portrait; the
"Fleet vehicle" chip + a Sightings row appear; frames are not black at dusk (exposure); the phone does not
overheat in ~10 min (live frames use `.fast` OCR + a rate-limited 6 s "escalation" to the thorough pass —
`CaptureViewModel.escalate`). If it overheats, raise the escalation interval or lower
`CaptureConfiguration.analyzeEveryNthFrame` cost.

**Likely tuning:** `CaptureConfiguration` (`minimumShutterSeconds`, `analyzeEveryNthFrame`),
`VisionBaselineAnalyzer.thoroughMinimumTextHeight`. Re-run `eval/` after any change.

---

## 3. Improve plate reading  *(the weakest part — see EVALUATION.md)*

**State:** only 9–11 of 62 corpus images yield a plate; reads that exist look real. Baseline = Vision text
OCR + a plausibility filter (`Plate.isPlausibleReading`) + plate-rectangle crops (stills only).
The CoreML plate detector/OCR is **not wired into the pipeline**: `PlateAnalysisPipeline` only runs a CoreML
*vehicle* detector when installed; `plate-detection`/`plate-ocr` entries exist in `models/registry.json` but
no stage consumes them.

**Plan:**
1. **Ground truth first.** Add a `plate` field to `eval/manifest.json` for images where a plate is legible
   (hand-label; keep it out of any shared DB). Extend `eval/harness/Sources/EvalHarness/main.swift` to score
   exact-match and character-error rate. Without this you cannot tell improvement from noise.
2. **Plate detector stage.** Add a `CoreMLDetectorStage(task: "plate-detection")` use in
   `PlateAnalysisPipeline.analyze` (the stage already exists), crop each box, upscale, OCR with Vision
   `.accurate`; keep the plausibility filter. Compare against the rectangle-based reader.
3. **Plate OCR model** (`plate-ocr-trocr-small`): converter path for TrOCR is not implemented
   (`scripts/convert_models.py`, see HANDOFF §3). Optional — Vision on a good crop may be enough.
4. Multi-frame fusion (`VehicleML/MultiFrameFusor`) exists; confirm it is actually used on the live path
   before relying on it.

**Done when:** the harness reports a plate exact-match rate and it beats the current baseline on the same corpus.

---

## 4. Publish models + fix `ModelManager`  *(unverified value — do after §3 step 1)*

**State:** converted `.mlpackage`s exist only in the untracked `models/cache/` on one dev machine.
`models/registry.json` URLs point at a `models-v0.1.0` GitHub release that **does not exist**. Placeholder
entries (`REPLACE_AT_CONVERSION_TIME`) are now skipped by `ModelRegistry.latest`.
`ModelManager.downloadAndCompile` treats the single downloaded file as the model — but a `.mlpackage` is a
**directory**, so even a published release would fail.

**Steps:**
1. Package each model as an Apple Archive: `aa archive -d <model>.mlpackage -o <model>.aar -a lzfse`
   (decode on-device with the `AppleArchive` framework: `ArchiveByteStream.fileStream` →
   `decompressionStream` → `ArchiveStream.decodeStream` → `extractStream`). Point registry `url` at the `.aar`,
   `sha256` at the **archive** bytes (`shasum -a 256`).
2. Implement extraction in `ModelManager.downloadAndCompile`, then `MLModel.compileModel(at:)` on the extracted
   `.mlpackage`. Add a test that round-trips a tiny archive.
3. Check each model's **license** before publishing (AGENTS.md guardrail 5; record in `registry.json`
   `license`). The YOLOv8 entries are AGPL-3.0; verify the ViT classifiers' terms. **Do not commit weights.**
4. `gh release create models-v0.1.0 *.aar` and update `registry.json` hashes. The app fetches
   `https://raw.githubusercontent.com/noktirnal42/PlateWatch/main/models/registry.json` — so the registry must be on
   `main` **and** the release assets must exist, or the app makes failing requests (harmless but noisy).
5. Surface model state in About (`SettingsView` reads `PassiveCaptureStatus.modelStatus`).

**Done when:** a fresh install downloads, verifies and loads a detector, About shows it, and the eval does not regress.

---

## 5. Lift fleet recall with a fleet-specific classifier

**State:** 57 % automatic recall at 100 % precision (EVALUATION.md). Misses: stylized lettering, distance,
glare, unmarked cruisers (undetectable by design), buses/USPS (weak cue).

**Options (in order of effort):**
- Grow the eval corpus (`python3 eval/fetch_corpus.py --per-query N`, then **curate by eye** with contact sheets —
  search results are noisy; non-US/toy/historical/interior images must be excluded) so changes are measurable.
- Add Apple classifier labels to `VehicleCueClassifier.labels` if useful ones exist (the label set was inspected on
  this corpus: `police_car`, `firetruck`, `ambulance`, `bus`, `truck`, `van`, `jeep`, `suv`… — check others).
- Train/fine-tune a fleet classifier (police/fire/EMS/transit/public-works) on a **licensed** dataset; record the
  license in `docs/DECISIONS.md` first (see `docs/PLATE-DESIGN-DATASET.md` for the licensing-gate pattern).
- Livery colour/pattern cues; roster matching (`knownUnitMatch` in `RedactionGate` is plumbed but always `false`
  in the app — wire it to cached public fleet rosters from FleetImporters).

**Guardrail:** never lower the 0.55 automatic threshold to gain recall; add evidence or use the review queue.
Re-run `EvalHarness`; precision must stay 100 % with 0 civilian/commercial false positives.

---

## 6. Visual redesign  *(functional + branded now, not final)*

Done: icon, launch screen, accent colour, onboarding, About, empty states, Explore map, informative rows.
Open (from `docs/QA-REPORT.md` P2): Sighting **detail** view (image/clip preview, share/export, retract),
watchlist validation + alert history (state patterns exist in PlateKit), Settings (mirror URL, delete-my-data),
haptics/sound on a fleet hit, **VoiceOver** descriptions for overlay boxes, **Dark Mode + Dynamic Type audit**,
landscape layout (dashcam use), iPad. Design tokens: `apps/ios/Sources/DesignSystem.swift`, colours in
`Assets.xcassets` (`PWAmber`, `PWInk`, `LaunchBackground`, `AccentColor`).

### 6b. Painted app icon
The shipped icon is generated in code (`scripts/make-brand-assets.swift` → `Assets.xcassets/AppIcon`). A
painted version was requested; the **Blueprint Studio Asset Generator** MCP server needed authorization (the
owner enables it in claude.ai connector settings; an agent cannot start OAuth). Brief used: 1024×1024 PNG,
full-bleed, no transparency/rounded corners, amber `#FFC21A` plate with "PW" inside viewfinder brackets on
`#0E1116`, readable at 60 px. Drop the PNG at `apps/ios/Sources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`
and update `site/logo.svg`/favicon if the mark changes. Ask the owner before swapping.

---

## 7. Unverified targets

- **watchOS app / macOS Hub:** not built or run in the latest passes (`apps/watchos`, `apps/macos-hub`; `xcodegen`
  in each; they also use the optional `project.local.yml`). Build both, run on a watch/Mac, check the Hub's
  folder-watch and Bonjour endpoint, and `PushHandler` (watchOS) which has no tests.
- **CarPlay:** `CarPlaySceneDelegate` + the `UIApplicationSceneManifest` entry exist but Apple's CarPlay
  entitlement must be requested/granted first; until then gate the scene behind a build setting and verify the
  SwiftUI window scene still works on all OS versions.
- **CI:** `.github/workflows/ci.yml` should build the iOS app, FoundationModelsParser (has **0 tests**) and
  run the eval harness build; verify the matrix matches current targets (QA P2-12). Pages deploys from `main` via
  `.github/workflows/pages.yml`.

---

## 8. Smaller known gaps

- `userConfirmed` is **not** a DTO field: a confirmed review item is submitted at the 0.55 persist floor, which the
  server files as `pending`. If moderators need to know it was human-attested, add an optional field to
  `PlateKit/DTO/SyncDTOs.swift` **and** `server/Sources/App/DTO.swift` (they must stay field-compatible) + a migration.
- Vision's reported OCR confidence is ~1.0 for nearly everything, so displayed plate confidence is not meaningful.
- All-letter vanity plates and all-digit plates are rejected by `Plate.isPlausibleReading` until a plate detector exists.
- School buses and charter buses are ambiguous (`bus` cue is down-weighted ×0.6 and needs transit text).
- `docs/ROADMAP.md` is the source of truth for progress — **do not tick boxes you have not verified**. During this
  work an unrelated process edited the roadmap to mark exposure tuning and RTSP ingest ✅ with no verification;
  it was reverted. Treat roadmap diffs you did not write with suspicion.

---

## Working notes / gotchas (saves hours)

**Run everything**
```bash
for p in PlateKit CaptureKit VehicleML PlateSync FleetImporters; do swift test --package-path packages/$p; done
swift test --package-path server                      # 41 tests; needs no database
(cd apps/ios && xcodegen && xcodebuild -project PlateWatch.xcodeproj -scheme PlateWatch \
   -destination 'id=<SIM or DEVICE UDID>' -derivedDataPath /tmp/pw-dd build)
(cd eval/harness && swift build -c release) && eval/harness/.build/release/EvalHarness eval
```
Current baseline: **155 tests green**; eval = 100 % precision, 0/14 civilian FP, 57 % auto recall (Mac).

**Signing:** team ID + name live in the gitignored `apps/*/project.local.yml` (copy `project.local.example.yml`).
`xcodegen` regenerates the (gitignored) `.xcodeproj`; never commit it.

**On-device check without a screen** (works while the phone is locked/mirrored): copy images with
`xcrun devicectl device copy to --device <UDID> --source x.jpg --destination Documents/selftest/x.jpg --domain-type appDataContainer --domain-identifier org.platewatch.PlateWatch`,
then `xcrun devicectl device process launch --device <UDID> --terminate-existing --console org.platewatch.PlateWatch -- -PWSelfTest`
(note the `--`: otherwise `devicectl` eats `-PW…` as its own flag). Implemented in `apps/ios/Sources/SelfTest.swift` (DEBUG only).
The launch is **denied if the phone is locked and not mirrored** — reconnect iPhone Mirroring first.

**iPhone Mirroring (computer-use):**
- The iPhone must be **locked** to connect ("iPhone in Use" otherwise); launching an app from the Mac can wake it and
  drop the session — press **Resume**/**Connect** again.
- Photo-library access triggers a **Touch ID / Mac-password** prompt. Agents must not enter passwords — ask the owner.
- Background `app_type` and drag-swipes do **not** reach the phone; clicks do. Open apps via `devicectl … launch` instead
  of Spotlight. The camera is never available through mirroring.

**Simulator:** `xcrun simctl privacy booted grant camera|photos|location <bundle>` **terminates** the app (relaunch
after). System permission alerts ignore synthetic taps — pre-grant instead. The first tap after a fresh launch is often
swallowed; tap again. Add test photos with `xcrun simctl addmedia booted <file>`; the sim has no camera, so use photo
import (the app shows a branded "No live camera" card).

**Eval data hygiene:** images live in `eval/corpus/` (gitignored — some show civilian plates); only
`eval/manifest.json` (source page, license, author, labels) is committed. Do **not** turn corpus photos into
fabricated "sightings" in any shared database.

**Crash reports:** `~/Library/Logs/DiagnosticReports/PlateWatch-*.ips` — the CoreLocation crash was found this way.
