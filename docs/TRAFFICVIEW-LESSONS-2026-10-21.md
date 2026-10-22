# Lessons from TrafficView (2026-10-21)

TrafficView (`/Volumes/Artificial_Intelligence_Machine_Learning/dev/TrafficView`, the owner's separate app) is a viewer: it plays NV511/AZ511/UDOT
HLS streams and draws labelled target boxes. PlateWatch Hub is an accountability tool with a policy gate, redaction rules and records. The
purposes differ; this note records what PlateWatch borrowed **by pattern** (re-implemented, no files copied) and what it deliberately did not.

## What I looked at
Source: `Video/HLSDecoder.swift`, `UI/VideoSurface.swift`, `UI/OverlayCanvas.swift`, `Vision/IoUTracker.swift`, `Vision/VoteTally.swift`,
`Vision/AnalysisPipeline.swift`, `Map/CameraMapView.swift`, `UI/MapTabView.swift`, `docs/DESIGN.md`. Visual QA: built and ran TrafficView
2026-10-21 — grid wall of live tiles, single view with inspector, map tab with camera pins and a Watch live card. NV511 tiles played as moving
video; analysis stays off until a person records the provider's terms in TrafficView's own Settings (I did not record any decision for the owner;
the owner then enabled it and I saw dashed/solid boxes with two-line chips ("Car / Make unclear") and a track inspector).

## Why TrafficView's NV511 video looked "live" and PlateWatch's did not
1. **Playback vs sampling.** TrafficView puts the decoder's `AVPlayer` straight into an `AVPlayerLayer`; analysis taps the same player for frames.
   PlateWatch's Live pane only showed the *analysed still* (about one per second), so even a healthy stream looked like a slideshow.
2. **A short attempt window.** PlateWatch gave the pinned stream 15 s to deliver a frame, then dropped and retried every 5 s. The NV511 hosts are
   often slower than that: measured 2026-10-21, `d2wse2.its.nv.gov` took ~8 s to connect and ~9 s to first byte, and another playlist request got no
   answer in 60 s (plain `curl`, same as the app). Result in PlateWatch: connect attempts failed with -1001 / NWError 57 for a minute before one worked.
   TrafficView shows the same upstream behaviour ("Connecting", black tile, "The requested URL was not found" on a retired route) — it is not magic.
3. **Policy relay.** PlateWatch plays through `HLSPolicyRelay` (reviewed origins + robots on every playlist/segment). TrafficView plays catalogue
   URLs directly. The relay is a deliberate guardrail and was kept; it adds latency, not correctness problems that I could prove.

## Built in PlateWatch (this session)
- **Moving video in Live:** `HLSFrameSource.player` is public; `FeedRunner.livePlayer(for:)` / `isStreaming(_:)`; `LivePane` shows `LiveVideoSurface`
  (AVPlayerLayer) once the decoder reports frames, with the analysis overlay on top that fades when its frame is older than 4 s. Still image remains the
  fallback while connecting and for snapshot feeds.
- **Target boxes in TrafficView's style** (`VehicleBoxCanvas`): dark casing under a coloured stroke so boxes read on sky and asphalt, rounded corners,
  dark glass chips with a colour-keyed edge, chips clamped inside the picture, no chip on tiny boxes, spoken summary for accessibility. Colours:
  vehicles cyan, fleet hits green (replaces yellow/green); legend updated.
- **Patience and backoff:** the Live-pinned HLS decoder waits 40 s (others 15 s); `HLSFrameSource` retries with exponential backoff
  (base, 2x … 60 s, reset on any delivered frame) — unit-tested.
- **Map pane** (new sidebar item): every catalogue camera on MapKit with clustering ("1,219 cameras"), Standard/Satellite/Hybrid, "Confirmed only",
  click a pin → card with city/state, provider, status and **Open in Live** (same terms/block gates), favourite toggle. Positions are geohash-6 centres
  (~1 km). Pins: teal = terms confirmed, gray = awaiting, amber = favourite/selected.
- **Show on map** (Public feeds → selected camera): switches to the Map, centres, zooms to ~6 km and highlights the pin (amber, on top, un-clustered) —
  matching the behaviour the owner added to TrafficView the same day.

## Not taken (and why)
| TrafficView idea | Decision |
|---|---|
| Per-provider terms store and "Viewing only" mode | PlateWatch already has per-host terms with a human decision; unchanged |
| Colour by vehicle family; dashed stroke for uncertain type | Our boxes carry no per-box confidence/family yet. Candidate follow-up: add `classConfidence` and body family to `LiveFrameResult.Box` |
| IoU tracker + vote smoothing for stable labels | Worth doing, bigger change: needs track IDs across frames in `analyseFeedVideoFrame` (ours are per-frame UUIDs) |
| Right-hand track inspector | Candidate follow-up after tracks exist |
| Multi-tile live wall | Conflicts with the four-stream budget and per-host politeness; not started |
| USGS topo map style | Not needed for the accountability use; Standard/Satellite/Hybrid only |
| Direct playback without the policy relay | Rejected: the relay is the robots/origin guardrail |
| Plate-state/AGPL | TrafficView re-implemented PlateWatch patterns; going back the other way is by pattern only |

## Verified vs only built
Verified in the running Hub: Map pane renders 13,332 pins in clusters; Live shows moving NV511 video with the new boxes (McCarran & Caughlin/Cashill,
10 vehicles detected) once the stream connects. Built but not exercised: "Show on map" end-to-end click path (see NEXT-STEPS), the 40 s patience (the
upstream stayed slow), cluster-title change. No Hub XCTest changes beyond the backoff test in FeedIngest.
