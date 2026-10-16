# Hub repair and verification — 2026-10-15

Workstream: WS2. The newer `codex/agent-bridge` branch is the continuation baseline. The older
`feat/hub-moderation` checkout is behind it. Both original checkouts' local edits were preserved;
repairs live on `codex/hub-repair-20261015` in a separate worktree.

## Repaired behavior

- Repaired the unfinished Nevada importer and Review edits without dropping the newer records,
  agent bridge, HLS transport or visual work. Review supports Command/Shift multi-selection,
  Select all, Clear selection and one local rejection operation. Failed saves are reported.
  Thumbnail buttons still open the full image; the viewer now fits the bounded crop's native size.
  Compact two-line timestamps and bounded columns keep the review table usable at narrow sizes.
- Live, Review and Records retain state across sidebar navigation. Records subtabs retain their
  forms/search/selection while switching tabs. FOIA draft fields and chosen Records tab persist
  across launches; credentials remain in Keychain. Camera selection persists, while local camera
  capture pauses on leaving Live. Video playback retains its position for explicit Resume.
  A selected public feed remains selected across navigation. Inactive retained controls are disabled
  and hidden from accessibility. The console is a single Window; Navigate no longer creates copies.
- Evidence conversion uses Core Image's actual pixel-format conversion; it never copies YUV bytes
  into a BGRA buffer. Crops reject invalid/out-of-frame boxes and omit the image if redaction cannot
  complete. JPEG encoding, size cap, digest and overlapping-vehicle refusal have regression tests.
  The eight existing user queue rows contained **no image bytes or crop hashes** before repair;
  those old images cannot be reconstructed from the stored DTOs. They were not deleted or fabricated.
- The outbox counter loads the real persistent count at startup and updates after rejection.
- Successful manual snapshot refresh clears a stale image-failure diagnostic and restarts a suspended
  poller. HTTP/media/network failures are distinct from policy failures; received-frame timestamps
  are available through the app bridge. Status-filter/sort refresh follows coalesced state revisions,
  including changes whose aggregate status counts stay the same.

## Nevada and HLS

The Keychain credential successfully fetched the [official NV511 camera API](https://www.nvroads.com/help/endpoint/cameras):
661 camera objects produced 652 enabled snapshot entries and 628 HLS entries. Multiple enabled
views and their distinct media URLs retain stable identities, state, surveyed camera positions and
source citations. Import never confirms terms or stores the API key in catalogue/media URLs.
The owner's explicit human approval of the Nevada media hosts was received on 2026-10-15; existing
recorded approvals, favorites and blocks were preserved. The normal catalogue now has 9,727 media entries.
These are catalogue entries, not a count of online cameras or accurately recognized plates.

- Open in Live accepts HLS. Ordinary live streams use AVPlayerItemVideoOutput rather than
  AVAssetImageGenerator, which requires an optional I-frame rendition for HLS still extraction
  ([Apple](https://developer.apple.com/documentation/avfoundation/creating-images-from-a-video-asset)).
  Bounded previews stop their decoder on success, timeout or cancellation.
- Only the selected HLS source decodes continuously, at a one-second tap interval. Approving a
  large catalogue does not start hundreds of AVPlayers. Other HLS entries say “HLS ready · open in Live.”
- Four Nevada video origins returned a generic Wowza welcome page at robots.txt with HTTP 200.
  A cited exception accepts only that identified placeholder, eight exact official video hosts,
  HTTPS/default port, and published regional `.stream/*.m3u8` routes. Other HTML, valid Disallow,
  401/403/429, unrelated paths/hosts and TLS/network failures remain closed. This is an intentional
  operator-publication exception, analogous in purpose to the existing Caltrans exception;
  it is not a general HTML/200 permission rule. Tests cover scope and real refusals.
- AVPlayer still owns child playlist/segment/CDN requests. Full per-segment policy enforcement is
  **not implemented**. Raw RTSP still needs its separately licensed transport; neither milestone
  is marked complete merely because one HLS camera works.

## Evidence obtained

- FeedIngest: **156 tests passed**, including opt-in generated loopback HLS delivery, bounded sink,
  stop/restart/retry and parsing the saved official Nevada response. No upstream key is in a fixture.
- Hub: **28 tests, zero failures** in the final offline run (four opt-in checks skipped there).
  Separate opt-in runs passed ordinary HLS preview/cancellation, real NV511 HLS decoding, and an
  offscreen synthetic Review render. The first render harness had an NSWindow cleanup crash;
  disabling release-on-close corrected it and the subsequent render test passed.
- All **ten existing unblocked favorites** returned image data through the native FeedRunner preview
  path: three Austin, two Caltrans, Morton, three WSDOT airport views and Sandy. This is a sample
  at the verification time, not an assurance that every catalogue entry is online.
- Signed local build, strict bundle verification, installation and process launch succeeded.
  The previous installed app was backed up before replacement. The final app runs normally,
  without the synthetic QA flag. Real queue count remained eight; stars/blocks/credentials stayed intact.
- Running installed app: NV511 “Airport Connector NB Grier · HLS” displayed moving traffic, repeatedly
  updated analysis timestamps and vehicle overlays. A Dashboard → Live round-trip retained the source.
- Running synthetic isolated QA: thumbnails, full-image sheet, Select all and bulk rejection were
  exercised; three selected test records became zero. No actual user queue entries were rejected.
- FOIA draft values survived a Dashboard round-trip; temporary test field values were removed afterward.
  The console stayed a single window. Native CUA attachment repeatedly failed; the user explicitly
  authorized window screenshots and accessibility scripting as the alternate QA method.
- MCP adapter: **five Python regression tests passed**. No camera or person-record screenshots are
  committed or published by this pass.

## Reproduce

```sh
swift test --package-path packages/FeedIngest
xcodegen --spec apps/macos-hub/project.yml
xcodebuild -project apps/macos-hub/PlateWatchHub.xcodeproj -scheme PlateWatchHub \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath build/hub \
  -parallel-testing-enabled NO -collect-test-diagnostics never test
./script/build_and_run.sh --verify
```

The run script accepts an optional `PLATEWATCH_DERIVED_DATA_PATH` override. Opt-in test inputs:
`PLATEWATCH_HLS_FIXTURE_URL` (loopback synthetic HLS), `PLATEWATCH_NV511_FIXTURE_PATH` (saved API JSON),
`PLATEWATCH_APPROVED_NV_STREAM_FILE` (approved official stream URL), `PLATEWATCH_FAVORITES_AUDIT_PATH`
(approved unblocked saved favorites), and `PLATEWATCH_QA_ARTIFACTS` (offscreen synthetic output folder).
For xcodebuild, prefix environment names with `TEST_RUNNER_` to forward them to the hostless runner.
Debug `-PWVisualQA` uses an in-memory queue and isolated temporary catalogue/records; never leave that
session in place of the owner's normal app. No source credential, model weight or local-data link belongs in Git.

## Planned work still open

1. Enforce policy across HLS child playlists, redirects, keys and segments, with cross-origin fixtures;
   add a small sustained camera-quality/freshness/CPU pilot. Existing real HLS proof does not close this gate.
2. Physical Continuity/UVC, permissions, disconnect recovery and handheld/watch QA require actual hardware.
3. Internal on-device Foundation Models/MLX agents, activity journal/budgets/stop control and the optional
   PCC provider remain the separate implementation sequence in AGENT-INTEGRATION.md. The external MCP
   interface is working; it is not an implemented internal agent runtime.
4. Remaining release/CloudKit/two-account/publication and broader cross-platform work stays in ROADMAP.md.
   No notarization, server deployment, paid court query or publication is claimed here.
