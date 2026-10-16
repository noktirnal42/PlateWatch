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
  into a BGRA buffer. Crops reject invalid/out-of-frame boxes. Owner clarification on 2026-10-15
  removes local overlap refusal and plate/text blackouts: intact fleet-target crops are required
  for Review. JPEG encoding, size cap, digest, overlap preservation and text preservation have
  regression tests. REST/CloudKit do not upload these local image bytes.
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

The HLS relay cancellation path was hardened after native QA captured an
`EXC_CRASH` in `URLSession.bytes(for:)` during session invalidation. Relay
shutdown now cancels active tasks individually, preserving bounded streaming
and the slow-segment first-chunk contract. A signed build remained alive for
the post-fix pilot window; longer CPU/memory and multi-camera soak testing is
still open.

1. Enforce policy across HLS child playlists, redirects, keys and segments, with cross-origin fixtures;
   add a small sustained camera-quality/freshness/CPU pilot. Existing real HLS proof does not close this gate.
2. Physical Continuity/UVC, permissions, disconnect recovery and handheld/watch QA require actual hardware.
3. Internal on-device Foundation Models/MLX agents, activity journal/budgets/stop control and the optional
   PCC provider remain the separate implementation sequence in AGENT-INTEGRATION.md. The external MCP
   interface is working; it is not an implemented internal agent runtime.
4. Remaining release/CloudKit/two-account/publication and broader cross-platform work stays in ROADMAP.md.
   No notarization, server deployment, paid court query or publication is claimed here.

## OpenCode continuation: selective feed analysis

Reconciled the older checkout's uncommitted watch controls with this repair baseline.
The persisted eye selection and the feed open in Live are now the only background
analysis inputs. Favorites and blocks remain independent; previews do not enroll a
camera. No existing stars, blocks or explicit watch choices are migrated or removed.
Snapshots that are confirmed but unwatched show idle. HLS watches are bounded to
four decoders, with Live taking priority; additional watches show their capacity wait.
Unwatch/block releases the decoder, and closing Live removes its temporary enrollment.
The existing HLS transport retry/stall state machine is retained rather than stacking
another watchdog over it. The caption filter already exists on this newer baseline.

Hub verification: 33 tests, four opt-in skips, zero failures. New coverage verifies
watch persistence, selective requests, enrollment/removal, cancellation during policy
lookup, preview independence, HLS decoder capacity, Live priority and decoder release.
The original OpenCode checkout and its unfinished edits remain untouched.

### Watch responsiveness regression and final native check

The first watch integration recomputed the selected HLS set inside a filter over
the entire catalogue. The owner reported a hang; this redundant nested scan was
removed and the selected set is now computed once per change. “Watch all favorites”
now also writes/publishes its union once. A 10,000-entry catalogue test exercises
69 watched cameras, mixed snapshot/HLS media, Live priority and removal; the final
run completed this test in 0.23 s. All 34 Hub tests passed (four opt-in skips).

The corrected signed build was installed. Actual native favorite-card Watch click
changed polling from one to two watched cameras, delivered analysis and kept MCP
and pane navigation responsive; toggling back restored the exact preceding watch
set. The table now also includes its Watch column (visual QA caught the omission).
Native screenshot and accessibility checks used the owner's previously authorized
fallback. This is targeted regression evidence, not an all-day soak or a claim that
no other crash exists. The latest observed real queue count is seven; no real queue
entries were rejected during this continuation. Existing user favorites/blocks and
watch choices were preserved. Recognition follow-up is documented in EVALUATION.md.

## Local evidence policy correction — owner clarification

The older OpenALPR checkout held an uncommitted removal of crop redaction/suppression,
but that change was absent from the repair branch and LEGAL-ETHICS still described the
strict rule. The prior repair therefore retained the unwanted behavior. The current
implementation removes both overlap-based crop omission and neighboring plate/text
blackouts for local Review. AGENTS, LEGAL-ETHICS, data-model, feed/agent docs, MCP/skill
descriptions and product copy now explicitly describe intact local evidence.

37 Hub tests pass (four opt-in skips), including byte-identical JPEG checks with overlapping
vehicles and neighboring text. A separate in-memory native QA session exercised the same
EvidenceCrop path with overlap/text fixtures: all three thumbnails displayed and the
overlap crop opened at 636 by 314 pixels without blackouts. The normal signed app was
reinstalled and its real queue preserved. This affects new captures; previously omitted
image bytes or destructively redacted pixels cannot be reconstructed from a crop hash.
REST continues to omit image bytes and CloudKit maps no image field.

## Future evidence recovery

New recorded crops now have a second owner-only local copy addressed by SHA-256. Review
backfills valid queued evidence and resolves absent/corrupt inline bytes from that archive;
the local agent evidence command uses the same verified resolver. Both copies remain
local. A digest without surviving bytes cannot recover older omitted photos. Intentional
rejection cleans up an archive only after the last queued reference disappears.
40 Hub tests pass (four opt-in skips), including missing/corrupt inline recovery, damaged
archive refusal/repair, invalid hash/path rejection, file permissions and shared-reference
deletion. This is protection against one payload loss, not a backup of the whole disk.

## Feed list recovery and general vehicle overlays

The owner reported only two cameras visible after clearing filters. Added one explicit
Clear filters action that resets the saved search/source/status together and reloads the
catalogue. Native QA reproduced the two-row view and restored 10,570 visible cameras from
the current 10,590-camera catalogue; 20 intentionally blocked entries remain in Blocked.
69 favorites and 68 watches were preserved. Counts are a current local snapshot, not a
claim that every endpoint was probed or returns fresh media.

The HLS budget previously selected the same first four watched IDs indefinitely. It now
rotates bounded background windows every minute and pins the camera open in Live. Queued
cameras are sampled in turns, not all decoded simultaneously. A regression test covers all
11 watched streams across rotations with Live pinned and no more than four scheduled slots.
Native runtime timestamps confirmed eight distinct watched HLS cameras receiving after
rotation; the previously failing Tonopah preview displayed and its opt-in native decode
test passed in 9.7 seconds. Transient/provider failures still require per-feed diagnostics.

Generic CoreML car/truck/bus/motorcycle labels now survive fusion as body-type attributes,
independently of fleet identity. Ordinary boxes show the body class rather than unknown 0%;
fleet labels retain a separately named fleet score. No generic body class promotes a fleet
hit or expands recording. Native Live displayed Car and Truck on the Austin 12th/IH35 feed.
These are coarse model predictions, not proof of make/model or fleet affiliation.
45 Hub tests pass (four opt-in skips); the separate Tonopah opt-in run passed. All 37
VehicleML tests pass with the local-image holdout opt-in skipped.
