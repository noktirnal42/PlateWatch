# QA Report — 2026-10-13

First end-to-end QA pass over the iOS app, the packages and the reference
server, run against the iPhone 17 Pro simulator (iOS 27.0) and a physical
iPhone 16 Pro Max (iOS 27.0.1). Findings are ranked by how much they block the
product from doing its one job: **read a plate on a government vehicle and
publish a sighting.**

**Verification key** — ✅ reproduced and observed · 🔎 confirmed by reading the
code or logs · ❓ suspected, needs a device pass to confirm.

> Scope note: the app was built, signed, installed and launched on the physical
> iPhone, but its screen could not be captured remotely, so on-device visuals
> and the live camera path are ❓ until someone drives them by hand. The
> simulator walk-through (all four tabs) is ✅.

## Resolution status (updated later on 2026-10-13)

Most P0/P1 findings were fixed the same day; accuracy is measured in
[EVALUATION.md](EVALUATION.md).

| Finding | Status |
|---|---|
| P0-1 frame orientation / overlay mapping | **Fixed** — `RotationCoordinator`, EXIF-correct photo decode, aspect-fill overlay mapping; regression tests |
| P0-2 nothing can be approved without models | **Fixed** — door-text vehicles, graded markings score, Apple classifier cue; 57 % automatic recall at 100 % precision on real photos |
| P0-3 model downloads 404 | **Mitigated** — placeholder entries are never fetched; models are optional. Publishing a verified release and archive extraction (`.mlpackage` is a directory) is still open |
| P0-4 detector labels do not map to fleet classes | **Mitigated** — Apple's built-in `police_car`/`firetruck`/`ambulance` cue. A fleet CoreML classifier is still planned (M2) |
| P0-5 CloudKit not live | **Partly fixed** — backend restructured (default zone, creator-only submissions, world-readable published types) and `cloudkit/schema.ckdb` written. **Still needs your Apple Developer step** to import + deploy the schema (see `cloudkit/README.md`) and a moderator tool to publish |
| P1-1 raw camera error text | **Fixed** |
| P1-2 notification prompt at launch | **Fixed** — asked on first watchlist add |
| P1-3 blank launch screen | **Fixed** — launch screen with brand colour + mark |
| P1-4 no app icon / accent | **Fixed** — asset catalog, generated icon (a painted version is pending image-generator access) |
| P1-5 stock tabs | **Improved** — onboarding, About, branded empty states, informative rows; a full visual redesign is still open |
| P1-6 Explore jargon / no map | **Fixed** — MapKit map of k-anonymous areas; aggregates now work on CloudKit too (client-side) |
| P1-7 orientation-lock warning | **Fixed** (`UIRequiresFullScreen`) |
| P1-8 CarPlay scene w/o entitlement | Open — needs Apple's CarPlay entitlement |
| P1-9 exposure tuning no-op | **Fixed** — auto-exposure with capped shutter, real device readout |
| P1-10 heavy `.accurate` passes on live frames | **Fixed** — live frames use `.fast`; `.accurate` only for stills |
| Server compile error + no-op HTML escape | **Fixed** |

### New bugs found and fixed while testing with real photos
- **Crash:** `LocationProvider` used `requestLocation()` without `didFailWithError` —
  CoreLocation asserts, so **any recorded fleet detection crashed the app**.
- Door text ("POLICE", "UNIT 4421") fit the plate-shape test and was consumed as a *plate*,
  hiding it from the markings parser.
- A plate near the image edge produced an out-of-range Vision region and failed the whole frame.
- `heatmap` was only a protocol-extension method, so `REST`'s real implementation was never called.
- `EMS` matched inside "SYSTEMS"; fleet keywords now match whole words (fuzzy for ≥ 5 letters).
- Brand words ("FALCK") were read as plates at 100 % confidence.
- CloudKit: custom zone on the public DB (unsupported) and unmoderated records/plates in the world-readable type.

## Test baseline (after the fixes in this pass)

| Suite | Result |
|---|---|
| PlateKit | 34 pass |
| CaptureKit | 16 pass |
| VehicleML | 13 pass |
| PlateSync | 13 pass |
| FleetImporters | 38 pass |
| FoundationModelsParser | 3 tests (struct/error-shape coverage; runtime availability remains device-gated) |
| server | 41 pass |
| iOS app (simulator + device, Debug) | builds |
| watchOS app, macOS Hub | **not built in this pass** |

Counts above are as of the end of the day; **155 tests** pass (the morning baseline was 129).

---

## Fixed in this pass

| # | Issue | Where |
|---|---|---|
| F1 | **Server did not compile** (`EventLoopFuture<Int>` passed where `Int` expected) — `swift build`/`swift test` for `server/` were broken on the working tree, contradicting HANDOFF's "24 tests pass". | `server/Sources/App/AgencyReportController.swift` |
| F2 | **HTML escaping was a no-op** in the agency report page: `"<"` was replaced with `"<"`. Agency names (imported from third-party CSVs) were injected into the page unescaped — stored XSS on a public page. Now escapes `& < > " '` in the right order. | same file, `render(_:)` |

---

## P0 — blocks the core loop (capture → read → publish)

**P0-1 · Camera frames are never oriented** 🔎 ❓
`PlateCaptureSession` never sets a video rotation on the output connection, and
neither `VNImageRequestHandler` call (`VisionBaselineAnalyzer`,
`CoreMLDetectorStage`) passes an orientation. A portrait phone delivers
landscape-right buffers, so Vision sees sideways text and plates will not read.
The overlay has the same fault: boxes are normalized to the *buffer* but drawn
over an aspect-fill, rotated preview, so they will be misplaced even when a
read succeeds. Photo-library import and the still shutter go through the same
path. *This is the most likely reason "it won't scan plates."*
Fix: set `connection.videoRotationAngle` (iOS 17+) from device orientation, pass
`orientation:` to every handler, and map overlay boxes through the preview
layer (`layerRectConverted(fromMetadataOutputRect:)`).

**P0-2 · Without CoreML models, nothing can ever be approved** 🔎
`VisionBaselineAnalyzer` returns every vehicle as `.unknown` with
`classConfidence: 0`. `RedactionGate.fleetConfidence` then depends only on door
text matching a fleet keyword or an exempt plate design hint. Sightings stay at
zero unless a cruiser's text happens to be read — and per P0-1 it usually isn't.
The Sightings tab will look permanently empty. There is also no "I saw a
cruiser, record it anyway" manual path.

**P0-3 · The model downloads 404** ✅ (simulator log)
`ModelManager` fetches `models/registry.json` from `main` and then
`…/releases/download/models-v0.1.0/*.mlpackage`. No `models-v0.1.0` GitHub
release exists, so every launch makes two failing requests and silently falls
back to baseline. `registry.json` also still has `REPLACE_AT_CONVERSION_TIME`
SHA-256 placeholders (`plate-ocr-trocr-small`, others) and a stale
`vehicle-detector-yolo11n` URL is requested although HANDOFF says YOLO11n was
dropped for YOLOv8n. Converted packages exist only in the untracked
`models/cache/` on the dev machine.
Fix: publish the release (weights stay out of git, per AGENTS.md), reconcile
the registry with what was actually converted, and show "Models: not installed"
in the UI instead of failing silently.

**P0-4 · Detector labels do not map to fleet classes** 🔎
The vehicle detector is stock COCO YOLOv8n (`car`, `truck`, `bus`…).
`VehicleClass(rawValue: label)` therefore resolves to `.unknown` for nearly
everything, and `CoreMLDetectorStage.fleetLabels` is declared but never read.
Even with models installed, no vehicle will be classified as fleet until a
fleet-specific classifier or fine-tune (ROADMAP M2) exists. The product
currently relies on door text alone.

**P0-5 · CloudKit backend is not live** 🔎
- `Info.plist` sets `PlateWatchUseCloudKit = true`, but nothing has been created
  in CloudKit: **no schema file is in the repo** (no `.ckdb`/`cktool` export),
  and `docs/BACKEND.md` only says record types "mirror DATA-MODEL.md".
- The container `iCloud.org.platewatch.platewatch` has to exist under the
  developer team, record types must be created (a Debug build with a dev-signed
  profile creates them on first save) and **deployed Development → Production**,
  and public-database security roles must allow anonymous/authenticated
  create+read as intended.
- The simulator build reports "REST mirror" on the Explore tab, i.e. it is
  *not* on CloudKit, and the HANDOFF note that `cloudKitAvailable` "always
  returns false" no longer matches the code (it now reads the plist flag).
  The two disagree; whichever is intended, the docs and the UI must say which
  backend is active.
- There is no on-screen indication of which backend is in use or whether the
  last sync succeeded beyond the outbox pills.

## P1 — broken or misleading UX

**P1-1 · Camera errors show raw Swift text** ✅
On the simulator (no camera) the capture screen prints
`camera error: The operation couldn't be completed. (CaptureKit.PlateCaptureSession.CaptureError error 0.)`.
`CaptureError` is not `LocalizedError`; there is no "no camera on this device"
state, and no suggestion to use photo import as the alternative.

**P1-2 · Notification permission is requested at launch** ✅
The system prompt appears over a blank screen before the user has seen what the
app is. Defer it until the user adds a first watchlist entry, with a sentence of
context.

**P1-3 · Blank white first frame** ✅
`UILaunchScreen` is an empty dictionary, so there is a white flash and no
branding while SwiftUI builds `ModelContainer` and starts services on the main
actor. Add a launch screen (brand colour + mark) and move non-essential setup
(`LocationProvider`, subscription call) off the critical path.

**P1-4 · No app icon, no asset catalog, no accent colour** ✅
There is no `.xcassets` anywhere under `apps/`. The home-screen icon is the
generic blank placeholder. No `AccentColor`, so the whole UI is system blue.

**P1-5 · Tabs are stock and unbranded** ✅
Sightings, Watchlist and Explore are default `List`/`Form` screens with large
titles and generic empty states. Nothing identifies the app. The one custom
element is the yellow shutter button, which reads as a stray dot against the
grey camera placeholder.

**P1-6 · Explore tab shows developer jargon and no map** ✅
It displays "Aggregates come from the REST mirror (PLATEWATCH_MIRROR_URL)…".
End users should never see an environment-variable name. `HeatmapView` contains no
map view at all; the server heatmap API (k=5) exists but nothing renders it.

**P1-6b · Status bar text is unfriendly** 🔎
`statusText` values like `scanning`, `processing still…`, `analysis failed` are
developer strings in a monospaced pill.

**P1-7 · Orientation locked to portrait with a build warning** ✅
`UISupportedInterfaceOrientations` is portrait-only but the target does not
require full screen: Xcode warns "All interface orientations must be supported
unless the app requires full screen." Dashcam/mounted use is naturally
landscape — this interacts with P0-1.

**P1-8 · CarPlay scene configured without the entitlement** 🔎 ❓
`Info.plist` declares a CarPlay scene and `CarPlaySceneDelegate` exists, but the
entitlements file has no `com.apple.developer.carplay-*` entry (Apple grants
these by application). Without it the scene is inert; and replacing
`UIApplicationSceneManifest` wholesale risks overriding the default SwiftUI
window scene on some OS versions. Verify on device; consider gating CarPlay
behind a build setting until the entitlement is granted.

**P1-9 · Exposure tuning is likely a no-op** 🔎 ❓
`extractExposureMetadata` reads `"ExposureDuration"`/`"ExposureISO"` straight
from sample attachments; those keys are not documented attachment keys (EXIF
lives under the `{Exif}` dictionary or must be read from `device.exposureDuration`
/ `device.iso`). If they come back nil, `AdaptiveExposureController` never
runs, and the session sits at a fixed 1/500 s shutter — which will crush night
and overcast footage to near-black.

**P1-10 · Always-on 30 fps analysis with `.accurate` re-reads** 🔎 ❓
Every analyzed frame runs `VNRecognizeTextRequest(.fast)` on the full frame and
then `.accurate` on every plate-shaped text region. With the broad plate
hypothesis rule (any text of 3–8 characters at aspect 1.0–4.5, including
"POLICE"/"STOP"), a street scene will trigger many accurate passes per frame.
Expect heat and battery drain on device; throttle by motion/track and tighten
the hypothesis filter.

## P2 — polish and gaps against the docs

- **P2-1** Sightings has no detail view, no image/clip preview, no
  share/export, and no way to retract a queued sighting.
- **P2-2** Watchlist has no state/region hint, no validation feedback (state
  patterns exist in PlateKit but are unused in the UI), and no alert history.
- **P2-3** No onboarding or first-run explanation of the legal/ethical model
  (fleet-only, redaction, on-device) even though it is the product's
  differentiator — `docs/LEGAL-ETHICS.md` is not surfaced in-app.
- **P2-4** No Settings screen: mirror URL, backend choice, model status,
  data/delete-my-data, and legal links all missing.
- **P2-5** No haptic/audio feedback on a fleet hit.
- **P2-6** Accessibility: overlay boxes and badges have no VoiceOver
  description of what was detected; fixed font sizes in the monospaced pills.
- **P2-7** Dark-mode and Dynamic Type were not audited.
- **P2-8** watchOS push handling (`PushHandler`) is new and untested; the
  macOS Hub was not built in this pass.
- **P2-9** `docs/ROADMAP.md` marks "iOS UI pass" done; the UI is functional but
  visually unfinished (see P1-4…P1-6).
- **P2-10** `apps/ios/project.yml` hard-codes `DEVELOPMENT_TEAM`. That is an
  identifier, not a secret, but contributors will have to override it; consider
  an optional `project.local.yml` include.
- **P2-11** Server: `HeatmapPage`/`AgencyReportController` were untested until
  this pass (the report page now builds; add tests for the escaping fix).
- **P2-12** CI matrix (`ci.yml`) should include the iOS app build and
  FoundationModelsParser; verify it matches the test targets above.

---

## Suggested order of attack

1. **P0-1** orientation (small change, biggest effect on "won't scan").
2. **P1-1/P1-2/P1-3** graceful camera/permission/launch states.
3. **P0-3** publish the model release; reconcile `registry.json`.
4. **P0-5** stand up CloudKit: schema export, dev→prod deploy, security roles.
5. **P1-4/P1-5** brand pass: icon, accent colour, launch screen, tab redesign.
6. **P0-2/P0-4** a manual "record this vehicle" path and a fleet classifier.
7. **P1-6** real map for Explore, wired to the k-anonymous aggregates API.

## How this was tested

- `xcodegen` → `xcodebuild` for the iOS simulator and for the physical device
  (automatic signing, team from `project.yml`); installed with `simctl` /
  `devicectl`.
- Simulator: cold launch, permission flow, all four tabs, console/network log
  review (`log show`).
- Code audit of the capture → analysis → gate → outbox path.
- `swift test` for every package and the server.
