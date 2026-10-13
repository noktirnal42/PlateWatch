# CAMERA-SOURCES.md — every way frames reach the analyzer

PlateWatch treats *frame sources* as interchangeable: anything that can produce
a `CVPixelBuffer` flows into `PlateAnalysisPipeline` and then the same
`RedactionGate` (fleet-only persistence, redaction, provenance). This doc tracks
each source, its status, and what is needed to finish it. USA focus for public
camera feeds.

Status legend: ✅ working · ⚠️ code exists but not working · ⬜ planned

| # | Source | Where | Status |
|---|--------|-------|--------|
| 1 | iPhone live camera (`AVCaptureSession`) | `apps/ios` + `CaptureKit` | ⚠️ implemented and unit-tested; **never run on a live feed** (iPhone Mirroring cannot expose the camera) — handheld field test pending, NEXT-STEPS §2 |
| 2 | Photo / video import (EXIF-correct) | `apps/ios` | ✅ |
| 3 | Hub folder watch — IP cameras FTP snapshots | `apps/macos-hub` | ✅ (Reolink/Amcrest-class cameras, on-prem, no cloud) |
| 4 | Hub Bonjour snapshot endpoint (devices POST frames) | `apps/macos-hub` | ✅ (filesystem-watch core shipped first) |
| 5 | Hub RTSP ingest | `apps/macos-hub/Sources/HubController.swift:409` | ⚠️ does not compile + wrong API — see §Network cameras |
| 6 | Continuity Camera (iPhone as webcam) | `apps/macos-hub` | ⬜ M6 |
| 7 | UVC webcams (any USB camera) | `apps/macos-hub` | ⬜ M6 |
| 8 | Public traffic cams / live feeds (HLS, snapshot JPEG, mJPEG) | `apps/macos-hub` | ⬜ M6 |

Why a range of sources: every additional legal frame source widens coverage of
taxpayer-funded vehicles (fixed intersections, depots, park-and-rides) without
asking volunteers to hold a phone. All sources share one rule set — the gate
does not care where the frame came from.

---

## Live iPhone camera (implemented, not field-verified)

`CaptureKit` runs `AVCaptureSession` with a `RotationCoordinator`-driven
orientation, capped shutter for moving traffic, and a rate-limited
analysis cadence (`CaptureConfiguration.analyzeEveryNthFrame`, 6 s escalation
to the thorough pass). Simulators have no camera; the Hub covers desktop
testing via sources 3–4.

## Folder watch + Bonjour snapshot (shipped, Hub v1/v2)

- v1: user picks a folder; cameras (or scripts) FTP/drop JPEGs in; a
  `DispatchSourceFileSystemObject` watch feeds `FileFrameSource`.
- v2: Hub advertises `_platewatch-snapshot._tcp` (Bonjour; see
  `HubController.advertiseBonjour`) and accepts POSTed frames on
  port 8088 — phones and cameras that can push snapshots skip the FTP hop.
- The operator sets `homeGeohash6` once per fixed installation (the geohash of
  the *camera*, which is stationary — more accurate than phone GPS).

## Continuity Camera (M6 — planned)

Apple's iPhone-as-webcam: on macOS 13+ with a nearby iPhone (iOS 16+), the
iPhone appears to AVFoundation as a normal capture device. Nothing about the
pipeline changes — it is just another `AVCaptureDevice`.

Implementation sketch (~1 day):

```swift
let discovery = AVCaptureDevice.DiscoverySession(
    deviceTypes: [.continuityCamera, .external, .builtInWideAngleCamera],
    mediaType: .video, position: .unspecified)
let devices = discovery.devices   // pick in a Hub settings picker
```

- Requires the Hub app to add the **Camera** usage entry and the user to enable
  camera continuity (same Apple ID, Wi-Fi + Bluetooth).
- Reuse the iOS capture tuning (capped shutter, analyze-every-Nth) — a phone
  over Continuity has the same thermal budget as a handheld.
- Verify device disconnection handling (`AVCaptureDevice.wasDisconnected`
  notification) — the iPhone walking away must pause the session, not crash.

## UVC webcams (M6 — planned)

Any USB webcam (Logitech, Elgato, a used DSLR via capture card) shows up as an
`.external` device on the same `DiscoverySession`. Non-UVC oddballs may need the
open-source **macam** driver. Deliverable: a camera picker in the Hub settings
(persisted by `uniqueID`), disconnection recovery, and a preview tile per active
camera. No special entitlements beyond Camera.

## Network cameras — RTSP rework (M6 — planned; current code broken)

`RTSPStreamHandler` (HubController.swift:409) exists but **does not compile**
(it calls a stale `RedactionGate.fleetConfidence(hasFleetMarkings:…)` signature
removed in the M-Alpha markings rework) and uses `AVAssetReader` on an
`rtsp://` URL, which AVFoundation cannot open for live streams.

Rework options, in order of pragmatism:

1. **HLS via `AVPlayerItemVideoOutput`** — works in pure AVFoundation today;
   covers every camera/NVR with an `.m3u8` output and most traffic-cam feeds.
2. **RTSP via VLCKit** (`MobileVLCKit`/`VLCKit`, LGPL-2.1, dynamic linking) —
   the universal fallback for `rtsp://` cameras. License must be recorded in
   `docs/DECISIONS.md` before the dependency lands.
3. mJPEG-over-HTTP: no AVFoundation support; prefer snapshot polling (below)
   unless a camera only offers mJPEG.

Whatever the transport, the handler ends at the same place: `CVPixelBuffer` →
`FramePacketLike` → `PlateAnalysisPipeline` → per-vehicle `RedactionGate`
verdict → outbox. Note the current handler also predates the `markings:`
gate parameter and `officialPlate:` evidence — rework must parse
`SceneTextHeuristics` markings like the iOS/EvalHarness call sites do.

## Public traffic cameras (M6 — planned)

State DOTs and municipalities publish camera feeds, but **access varies and several
need credentials** (verified 2026-10-13):

| Source | Access |
|---|---|
| 511NY | API **requires a registered account + developer key** and an access agreement; throttled (≈10 calls / 60 s) → out of scope until the owner opts in |
| WSDOT | Traveler Information API requires a free **AccessCode** → same |
| Caltrans | CCTV *dataset* (locations/status) is open via the California open-data/ArcGIS service; it lists cameras, **not live frames** — each camera's image URL must be checked separately |
| Mass511 and others | ⚠ unverified — read each agency's terms before listing |

Starter set rule: **keyless, published-for-public-use image URLs first**; keyed feeds only
with the owner's explicit opt-in and the key kept out of the repo. Formats in the wild:

- **Periodic JPEG snapshot URL** (most common; often an AXIS
  `/axis-cgi/jpg/image.cgi` style endpoint refreshed every 1–5 s).
- **HLS** (`.m3u8`) live streams.
- **MJPEG streams** (rare on DOT portals).

Design:

```swift
struct PublicFeedSource: Sendable, Codable {
    var id: UUID
    var name: String
    var url: URL                    // snapshot or .m3u8
    var kind: Kind                  // snapshotJPEG | hls | rtsp
    var refreshInterval: TimeInterval  // never poll faster than published cadence
    var geohash6: String            // static camera location
    var citation: SourceCitation    // where the feed URL came from + retrieval date
}
```

- A `FeedPoller` per source (single-flight, exponential backoff on failure,
  hard rate limit ≤ 1 fetch / refreshInterval) hands frames to the pipeline.
- **The gate rules do not change for public cams**: private plates seen by a
  traffic cam stay on-device/redacted exactly like handheld captures;
  only fleet-confirmed records persist, with the feed's `SourceCitation`.
- Politeness/legality: use only feeds published for public consumption, honor
  each DOT's terms, no authentication bypass, no aggressive polling, attribute
  the source in every derived record. Feeds requiring a license key are out of
  scope unless the owner of the key opts in.
- USA first (project scope): start with state 511 snapshot catalogs, curate a
  small starter set (10–20 feeds) behind a `feeds.json` + registry-style
  metadata, and keep the list in the repo (URLs only — no captured frames).

## Testing story per source

Every source must pass the same harness: `FileFrameSource` still covers 1–4;
sources 5–8 get a recorded-sample fixture (a short saved clip/snapshot set in
`eval/corpus/` or a fixtures dir) so CI never depends on a live camera. The
RedactionGate assertions in `PlateKitTests` remain the pass/fail authority.
