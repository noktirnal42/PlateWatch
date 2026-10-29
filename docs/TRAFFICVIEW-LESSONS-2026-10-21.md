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
| Colour by vehicle family; dashed stroke for uncertain type | Dashed stroke added 2026-10-21 for boxes whose type is unknown (label is just "Vehicle"); a first try keyed on class confidence < 50 % made nearly every box dashed (confidences are low even for obvious cars), so it was dropped. Per-family colour not done |
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

## Follow-ups done the same day
- Favorites tiles got a map button (Show on map). The installed MCP script was refreshed from the repo (previous copy saved in `~/.local/share/platewatch-mcp/config-backups/`); restart the MCP client to pick up the `map` pane and the RSS tools.

## Track smoothing and the HUD look (later the same day)
- **Box tracking in Live:** `LiveBoxTracker` (IoU ≥ 0.3 matching, up to 3 missed frames) gives each box a stable id and a 7-vote display label so "Blue Car"/"Blue Truck" flicker settles. Fleet status and the dashed "type unknown" flag always come from the *current* frame (a past fleet frame can never keep a box green; tested). Used only for the feed open in Live. 5 new unit tests (Hub: 59 tests, 0 failures).
- **Visual language (owner request: "cool and techy, like something a spy would use"):** `HubTheme` tokens (near-black base, single cyan accent, green = live, amber = waiting, red = fault), monospaced readouts, spaced uppercase overlines, thin accent corner brackets (`CornerBrackets`, `HUDPanel`), status chips (`HUDStatusChip`, pulse disabled under Reduce Motion), and a faint coordinate-grid backdrop behind every pane. Applied to the Dashboard (stat tiles, sections), the Live video frame (viewfinder brackets, "LIVE · HLS" / "SAMPLED STILLS" / "ACQUIRING" chip, `VEH n · T-ns` readout) and the Map card. Other panes (Public feeds, Review, Records, Settings, Models) keep their native controls on the new backdrop and tint; restyling them is the next pass. Verified by screenshot of Dashboard and Live; light mode and Increase Contrast were not inspected.

## Phosphor theme and base-element pass (owner feedback: "phosphor green rather than light blue; toggle to amber; treat the other base elements too")
- **Phosphor colour:** default classic green (`#3DFF86` dark / `#0B7A3B` light); Settings → Appearance → Phosphor switches to amber (`#FFB000` / `#9A6200`). The switch re-ids the console so every pane re-resolves its colours. Fleet hits on video and map favourites use the *contrast* colour (amber on green, green on amber); "waiting" chips are amber on green and pale ice on amber. Stored as `hubPhosphor` in UserDefaults.
- **Base elements restyled:** custom sidebar (phosphor bar + glow on the selected pane, "PLATEWATCH HUB" overline), `HUDGroupBoxStyle` for every `GroupBox`, `HUDButtonStyle` (outline) and `HUDProminentButtonStyle` (solid) replacing `.bordered` / `.borderedProminent` across the console, scroll/list/table/form backgrounds hidden so the grid backdrop shows through, map clusters in the phosphor colour. Public feeds, Review, Settings, Map, Dashboard and Live were inspected by screenshot in green; Dashboard in amber and in light mode.
- **Contrast check (WCAG ratios computed from the palette):** green accent on base 14.8:1, amber on base 10.7:1; light accent on white 5.4:1, light amber 5.1:1; secondary text ≥ 6.7:1. Tertiary text was 3.8:1 on dark and is now lightened (`#7F8D9A`); prominent buttons use white text on the darker light-mode fills (black on the dark-mode fills, 10:1+). **Increase Contrast** is a system setting that I did not toggle; the HUD borders use fixed opacities and may need a stronger variant when it is on (not verified).
- Second pass: one `hubChrome()` modifier (tint, HUD buttons/group boxes, hidden scroll backgrounds, optional grid backdrop, follows the Phosphor setting) is applied to the console, menu-bar popover, Help and Feed-terms windows and the terms-review sheet. Records and Moderation were inspected by screenshot (they inherit the console chrome). The popover and terms sheet compile with the same modifiers but were not screenshotted.
- **Increase Contrast variant (built, not observed):** with the system setting on, panels use a solid secondary-text border at 1.5 pt and full-strength corner brackets, buttons and chips get solid 1.4–1.5 pt outlines, overlines become bold primary text, the selected sidebar row fill doubles, and the grid/glow backdrop is dropped. I did not toggle the system setting (not mine to change), so this path has not been seen on screen.

## Overlay latency when a stream goes live (owner: "target box overlays are too slow", 2026-10-22)
- **Cause found:** the Live-pinned stream was analysed with the *full* pipeline once a second (detector + detail tiles + Vision text), so the first boxes only appeared after one full pass and then refreshed about once a second. TrafficView runs the detector on every sampled frame (up to ~5 fps) and does the heavy classification on an interval.
- **Change:** `AnalysisContext.boxesOnly` (detector on the whole frame + cheap type/colour, no text/plates/tiles). For the stream on screen the decoder samples every 0.25 s; frames use the fast pass, and a full pass runs in the background about every 1.2 s (the only one that scores or records fleet hits). `LiveBoxTracker.update(authoritative:)` lets fast frames move boxes while keeping the last full frame's label and fleet verdict. The HUD shows `BOX nms · FULL nms` and, when no frame has arrived for 6 s while "live", `NO NEW FRAMES · ns` in amber.
- **Measured on Las Vegas Blvd & MGM_Park Ave Arena (NV511 HLS):** once the stream reached "Polling" (~27 s after Retry, upstream-slow), boxes appeared with the first frames: BOX 5 ms, FULL 133 ms on this Mac. Then the **stream stopped delivering new frames** (the picture was identical 40 s later, HUD `T-43s`) and the Hub fell back to "sampled stills". That freeze is on the NV511 side (the same host showed NDOT's "technical difficulties" card earlier); it is not analysis latency. Frame rate while the stream *was* flowing was not captured for long enough to quote a sustained fps.
- Not verified: sustained ~4 fps overlay updates on a healthy stream (none of the feeds tried stayed healthy), and the fast pass's box quality versus the full pass.

## NV511 HLS in Live, follow-up (2026-10-22)
- **Why streams freeze:** timed with curl against the MGM stream (one 360×240 variant, 10 s segments of ~700 KB, ~58 KB/s needed): each segment took 12–16 s alone, and three fetched in parallel took 10, 37 and 42 s — the origin delivers roughly 50 KB/s in total, slightly below real time, so playback stalls in bursts for any client. TrafficView running at the same time (same address) and the Hub's own background HLS decoders competed for it; with TrafficView closed segments still took 12–20 s while background decoders ran. A clean no-competition measurement was not obtained.
- **Hub changes (all committed):** background HLS decoders are released while the Live stream is connecting and resume once it streams; the duplicate preview decode is skipped; pinned-stream stall limit 75 s; relay timeouts 30/60 s. Live now reaches "LIVE · HLS" with boxes on MGM and on McCarran & Caughlin/Cashill (verified by screenshot), but the picture still stutters because of the origin rate.
- **Overlay smoothness:** boxes are sampled ~10×/s (detector-only pass ≈ 10 ms on Release, full pass 70–95 ms), blended with the previous position (weight 0.65), glided along tracked velocity between measurements (30 fps redraw, ≤ 0.5 s, 0.07 s capture-latency lead), and drawn dashed until a full frame classifies the vehicle. Owner reported "it's ok now"; smoothness versus TrafficView was not measured objectively.
- **Known weakness:** on this 360×240 feed the type classifier labels dark cars as motorcycles at 34–60 % confidence; a "show Vehicle below a confidence threshold" rule was offered, not built.
- **Models:** TrafficView's make/model and type classifiers are the same Apache-2.0 `dima806` models PlateWatch already registers; its civilian/government (affiliation) model is not trained (only `tools/affiliation` scripts), so there is nothing to reuse.
- **Install:** `PLATEWATCH_CONFIGURATION=Release apps/macos-hub/scripts/build_signed_and_install.sh` builds and installs an optimised Hub.
