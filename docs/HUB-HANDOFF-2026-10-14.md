# Hub continuation and verification — October 14, 2026

Workstream: **WS2**. Continue from the current remote branch/main after reviewing PR #20; do not reapply the superseded uncommitted FeedRunner patch left in the older Claude checkout.

## Completed

- Continued Claude's desktop console: Dashboard, Live, Public feeds, Cameras & ingest, Review, Models, moderator-only Moderation and Settings. Retained the existing gold/charcoal PlateWatch icon family.
- Added persistent **⦸ block / ↶ unblock** beside favorites, on preview panels, favorite tiles and the selected web feed in Live. Blocking cancels camera polling and in-flight previews, clears the active Live view, hides blocked favorites, and preserves the star for restoration. All feeds / Favorites / Blocked make recovery explicit.
- Replaced optimistic host status with cancellable per-origin preflight and per-path robots decisions. Stopped generations cannot restart themselves; sibling paths are evaluated independently. Polls and previews share one cancellable per-host request budget; previews do not queue behind thousands of reserved future slots.
- Caltrans: verified real robots HTTP 500 while documented JSON/JPEG endpoints respond. Added a **cited, HTTPS host/path-scoped operator-publication exception** for those image branches and only robots HTTP 5xx. Valid Disallow, other hosts/paths, authentication/rate refusal and transport/TLS failures remain closed. This is an intentional exception to normal REP failure handling, not a repaired upstream endpoint. Human terms review remains mandatory.
- Hardened robots handling for HTML masquerading as a successful policy response and UTF-8 BOMs. Existing narrow S3 missing-key handling remains.
- Added Oregon TripCheck, Utah UDOT GIS and New Mexico NMRoads imports; removed the two Canadian menu choices. Every new camera remains **unconfirmed**. [USA access audit](research/USA-FEEDS-2026-10-14.md) covers Arizona, Nevada, New Mexico, Colorado, Utah, Alabama and additional candidates, distinguishing technical access from permission.
- Added **Open in Live** to selected camera previews and Favorites. For snapshot cameras it requests a rate-limited first frame, then displays frames from the existing background analysis with detection overlays. It retains that source's own geohash, jurisdiction gate, resolution tier, citation and deduplication key. Only the selected latest frame stays in memory. Leaving Live, stopping or blocking clears it.
- Live explicitly labels web snapshots; it does **not** imply continuous video. Local/Continuity capture and video-file frame analysis already exist. Public HLS decoding exists in FeedIngest but is not wired into this console or validated end-to-end; the snapshot runner now rejects video transports instead of fetching manifests as images.
- Added public-feed analysis count to Dashboard, responsive stat cards, a two-row feed filter/sort layout, explanatory tooltips, native glass for the main Live action on macOS 26+, and offline Help (Help menu / ⌘?). File → Show PlateWatch Console (⌘0) reopens the console.
- Moderation loads queue, takedowns and audit independently, with Refresh in every tab, progress/empty/error state and preservation of previous rows on error. Duplicate audit contents no longer collapse Table rows. The original server response was already decodable; no decoder root cause is asserted.
- Added a project-local Run action and `script/build_and_run.sh` for signed local build/launch/debug/logs. Added hostless Hub regressions to CI so tests do not start ingest, access Keychain or contact real camera hosts.

## Verification

Commands from the repository root:

```sh
swift test --package-path packages/FeedIngest
xcodegen --spec apps/macos-hub/project.yml
xcodebuild -project apps/macos-hub/PlateWatchHub.xcodeproj -scheme PlateWatchHub \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath build/hub \
  -parallel-testing-enabled NO -collect-test-diagnostics never test
./script/build_and_run.sh --verify
```

Use the optional, ignored `project.local.yml` for local signing. CI uses the checked-in team-free example. Signing and launch are local development evidence, not notarization or distribution approval.

- FeedIngest: **137 tests passed**, including scoped Caltrans grants, real-policy/auth/network refusal, HTML/BOM handling, Oregon multiview/filename safety, Utah migration and NMRoads enabled/fixed-camera filtering.
- Hub: **11 hostless regressions** cover upfront robots refusal, per-path siblings, stopped preflight cancellation, block/unblock and preview cancellation, unavailable images, star/block persistence, cancelled throttling, unsupported video transport, independent moderation failure and fractional/duplicate audit events.
- Running signed app: observed Austin camera analysis in Live with a vehicle overlay; rendered a selected Caltrans image; starred a temporary Caltrans test camera, saw it in Favorites, blocked it, saw it disappear from Favorites and appear in Blocked with disabled preview/Live controls. The local polling count dropped by one. Existing user stars/blocks were preserved.
- Running moderator pane: two existing takedown audit events loaded and displayed with timestamps and target IDs. No moderation decisions were made for testing.
- Test results are under ignored `build/hub/Logs/Test/`. Native UI automation intermittently failed with a SkyComputerUseService assertion; do not interpret that helper crash as an app crash or claim unperformed UI checks succeeded.

## Remaining work, in priority order

1. **Continuous public video:** preserve an operator-published stream URL as separately reviewed media access; implement AVPlayer playback with sampled analysis and the camera's own rules. Preflight/redirect/CDN/playlist/segment requests must respect operator permission and robots; do not simply pass an unchecked manifest to AVPlayer. Add a local deterministic HLS fixture, test cancellation/block/revocation, then verify a permitted real stream. Do not mark HLS/RTSP complete from package source alone.
2. **New host review:** Oregon, Utah, New Mexico and other newly imported hosts require a person to review/record terms before polling. Arizona/Nevada require developer keys, Colorado a supported access/data-sharing route, Alabama a supported inventory and permission path. Never commit keys or auto-confirm these decisions.
3. **Runtime coverage:** finish any relaunch/unblock restoration checks noted in the session, exercise search/filter/sort at narrow window sizes, and verify help/glass in light/dark and increased-contrast modes. Capture publication-safe screenshots (blocked/empty or synthetic media); do not commit unredacted private-vehicle camera frames as marketing assets.
4. **Hardware:** signed Location Services/Continuity permissions, actual UVC/Continuity camera analysis, network disconnect recovery and a real permitted HLS/RTSP source remain separate acceptance gates. The old RTSP AVAssetReader path compiles but is unsuitable for raw RTSP/live HLS; do not advertise it as proven.
5. **Product pilot:** verify timestamp freshness, camera-specific recognition quality, bounded CPU/network use and outbox publication on a small reviewed camera set. Polling status is a scheduler state, not an online/freshness guarantee. Snapshot camera coverage does not measure plate-recognition accuracy.
6. **Repository coordination:** preserve the older checkout's local patch until its owner compares it to the remote replacement. Do not reset another agent's checkout. Keep this handoff, PROJECTS WS2, CAMERA-SOURCES and the Pages feature status current.

For reproducible metadata imports in a **Debug** build, launch the app with `-PWImportCatalogues oregon,utah,new-mexico,wsdot,iowa`. This uses the same importer/merge path as Add cameras and never confirms terms. Existing approvals remain unless a source's image host changes. Avoid simultaneous import sessions. Release builds do not interpret that flag.

## Local metadata import result

The Debug importer completed with **8,447 total catalogue entries**: existing 4,225 plus 4,222 new entries awaiting terms. Accepted additions: WSDOT 1,706, Iowa 863, NMRoads 185, Utah GIS 308, Oregon 1,160. The raw Oregon inventory contained 1,161 views and Utah 482; entries without a valid ID, HTTPS snapshot URL or valid position are skipped. WSDOT includes several independently reviewed image hosts, including Oregon and third-party cameras. These counts are metadata validation, not a claim of 8,447 online cameras. Terms review is collapsed by default so many pending hosts do not crowd out the feed list.
