# iOS review and visual handoff — 2026-10-14

This is the current WS1 continuation note. Older HANDOFF/QA entries are historical;
use this note for the iOS review surfaces and `EVALUATION.md` for recognition evidence.

## Delivered

- Painted amber/graphite PW app icon, matching in-app brand art and website icon.
  The 1024-pixel opaque PNG is in `AppIcon.appiconset`; `BrandIcon.imageset`
  carries the matching artwork. The minimal SVG remains useful at small web sizes.
- Sightings now opens an observation detail: read markings or structured identity,
  evidence, capture time, coarse area, fleet evidence score and delivery state.
- Share exports an allowlisted **text summary**. It excludes device identifiers,
  exact coordinates, crop hashes and raw media. Unresolved agency names are not
  exported as facts. A score is explicitly not a calibrated probability.
- Paused outbox rows (eight failures) can resume automatic retries. The app
  distinguishes queued, retrying, attention-needed and paused states.
- Local discard and bulk queue/watchlist cleanup have confirmation and explicit
  save failures. They do **not** retract remote records or in-flight transfers.
- Watchlist input accepts 2–10 ASCII letters/digits (including short official and
  vanity formats), normalizes spaces/hyphens, rejects duplicates and requires
  public-fleet attestation. Alert mute/unmute and deletion rebuild the defaults
  copy from enabled saved entries. This fixes stale alerts after deletion.
- Dark/light semantic fleet text color replaces low-contrast amber text on light
  list surfaces. Rows reflow their metadata at larger text sizes. Overlay access
  describes fleet vehicle counts without reading background civilian plates.
- Landscape orientations and iPad multitasking are enabled in `project.yml`.
  Unavailable-camera content scrolls on short screens; still capture is disabled
  without a running camera. The signed iPhone 16 Pro Max build was exercised in
  both landscape directions on 2026-10-16; the preview layer and controls now
  rotate together. Dusk/motion/thermal and spoken VoiceOver coverage remain open.
- **Startup crash fixed in the iOS app boundary.** An unsigned simulator previously
  ran `SyncBackends.makeDefault()` with `PlateWatchUseCloudKit = true`; constructing
  `CKContainer` trapped. The app, environment default and notification delegate now
  share `AppSyncConfiguration`. Simulator builds use REST (default port 8083, matching
  the reference server), signed device builds retain PlateSync's CloudKit selection.
- Info.plist version values now follow `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`
  instead of a stale hardcoded version from the generated plist.

## Reproduce and test

```sh
cp apps/ios/project.local.example.yml apps/ios/project.local.yml # only if missing
(cd apps/ios && xcodegen)
swift test --package-path packages/CaptureKit
xcodebuild -project apps/ios/PlateWatch.xcodeproj -scheme PlateWatch \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=latest' \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
```

The scheme includes `PlateWatchTests` (validation, private-field export exclusion,
alert mirror and simulator backend regression) and `PlateWatchUITests`
(observation review/retry/discard, watchlist validation/add/mute/delete, local cleanup).

For screenshots, launch a **Debug** build with `-PWPreviewData -PWTab 1` (Sightings),
`2` (Watchlist), or `4` (About). This uses synthetic DEMO plates in an in-memory
SwiftData store and disables camera/location/sync/subscription/push/permission work.
A visible **DEMO DATA · LOCAL PREVIEW** banner identifies the fixtures. Alert edits
in this mode do not alter the normal notification defaults. Release builds ignore
these arguments. Never claim preview screenshots demonstrate recognition, capture
accuracy, CloudKit delivery or publication. Relaunch resets fixtures.

UI tests attach named screenshots in the result bundle. Export with:

```sh
xcrun xcresulttool export attachments --path <result.xcresult> --output-path <output>
```

## Design sources and asset provenance

The icon was generated with OpenAI's image-generation tool for this project,
then resized with `sips` for the asset catalog and website. No external artwork,
model weights or user photographs were committed. The existing viewfinder/plate
brand and amber/ink palette are preserved. Full-bleed bitmap icons support the
existing iOS 17 deployment target; layered Icon Composer variants remain future work.

The accessibility decisions follow Apple's [accessibility guidance](https://developer.apple.com/design/human-interface-guidelines/accessibility/):
semantic text styles, adequate contrast, labeled controls and layout reflow. Icon
layout was checked against Apple's [app icon guidance](https://developer.apple.com/design/human-interface-guidelines/app-icons/).
A screenshot audit does not replace a full spoken VoiceOver pass.

## Still required before a pilot

1. Import/deploy CloudKit schema, verify creator-only submissions with two accounts,
   build the moderator publication tool and prove the receipt→public-feed loop (WS5).
2. Handheld live-camera tests in portrait/landscape, daylight/dusk/motion, ten-minute
   thermal run and actual VoiceOver use (WS1). iPhone Mirroring cannot do this.
3. Remote withdrawal/removal flow and alert history are **not implemented**.
   Received-submission receipts and bounded local crop history are now retained;
   they do not constitute a public archive or retract a backend record.
4. Runtime-configurable mirror settings are still missing. Simulator development
   can set `PLATEWATCH_MIRROR_URL`; device backend configuration is owned by WS5.
5. Recognition improvements and the open model-release PR remain WS3. No accuracy
   claim was remeasured by this visual pass, and no weights were committed.
6. Physical watch push/haptics, CarPlay entitlement, signed release packaging,
   tint/dark/layered icon variants, and smallest-device/RTL accessibility audits remain.

See `NEXT-STEPS.md` for sequencing and `PROJECTS.md` for ownership.

## CI follow-up — 2026-10-16

The watchlist duplicate-validation UI test asserted a message while the keyboard could
obscure it. It now dismisses the keyboard and waits for the same duplicate warning,
without changing validation or weakening the assertion. The targeted add/mute/delete
flow passed on the local iOS 27 iPhone 18 Pro simulator. Full CI remains a separate check.
