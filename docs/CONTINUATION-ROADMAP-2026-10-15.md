# Continuing the greater roadmap — 2026-10-15

Owner instruction: continue priorities 1–7 and adapt suitable MLX/agent work from
other local projects. Keep each implementation/checkpoint scoped to its workstream;
preserve the older checkouts and their uncommitted work. The working branch extends
the Hub repair PR, not the older shared checkout.

| Order | Deliverable | Acceptance / remaining work |
|---|---|---|
| 1 | Reliable public feeds | Policy mediation for child resources/redirects, bounded decoder/preview use, delivery/content-change diagnostics, then a sustained native camera/CPU/memory pilot. |
| 2 | Recognition evaluation and improvement | Labeled camera geometry/class benchmark, measured misses/false positives, fleet classifier and OCR work. The one-SUV holdout is coverage evidence only. |
| 3 | Internal agents | Reuse audited shared-store/provider patterns; typed app commands, journal, budgets, Stop control, local Foundation Models and MLX with real packaged inference proof. |
| 4 | Accountability workflows | Exercise roster/court inputs, cited unit-to-official links and second-person review. No automatic record acceptance or publication. |
| 5 | Sync/publication | Reconcile CloudKit deployment claims with account state, verify creator-only/two-account behavior and build the reviewed publication workflow. |
| 6 | Devices | Verify available iOS/watch targets, permissions, disconnects, accessibility/thermal behavior and event retention; physical/CarPlay gates need actual evidence. |
| 7 | Beyond Apple | Read-only web/edge/Android consumers of the shared protocol, then deployment against a prepared service. Keep unavailable hosting/accounts explicit. |

Reuse findings: [local agent audit](research/LOCAL-AGENT-REUSE-2026-10-15.md).
Existing implementation and verification: [repair report](HUB-REPAIR-2026-10-15.md).
No row is complete merely because its view, dependency or scaffold builds.

## Priority 1 implementation

AVPlayer now receives private loopback routes rather than upstream media URLs. The
relay resolves/replaces playlist resource URLs, validates reviewed origins and robots
policy before upstream requests and redirects, and streams media in bounded chunks.
It supports normal playlist/segment/key/map/rendition references and byte ranges.
Variable-substitution and content-steering playlists are explicitly refused until
implemented; no unmediated fallback is used. A cited Nevada Wowza-placeholder rule
also covers the media extensions inside the published stream routes; real Disallow,
authentication, TLS and unrelated-path failures remain closed.

Root playlists are buffered up to 1 MiB for rewriting; media responses are limited
to 8 MiB and forwarded in 32 KiB chunks. Each relay has a private capability path,
loopback-only listener, at most eight connections and bounded route history. Stop
cancels the listener and upstream tasks. Favorite HLS previews share two decoder
slots, separate from the four watched streams. Snapshot hashes are transient local
state; Live distinguishes receipt time from unchanged content without declaring a
static scene a broken camera.

The initial fully buffered relay delayed slow Nevada streams and was replaced with
streaming before installation. A real whole-segment QA fetch also hit an upstream
transfer timeout. The bounded live probe now follows playlists and reads initial
segment bytes; synthetic fixtures verify complete body/range delivery. Neither is
a claim that every camera or network can sustain its advertised bitrate.

Verification: 163 FeedIngest tests passed with loopback and approved-stream probes
(one unrelated saved-API fixture skipped); 36 Hub tests passed in the final offline
run (four opt-ins skipped). A separate native test run passed real NV511 decoded
preview and loopback preview/cancellation through the relay. The signed app was
installed after a recoverable backup. Four existing watched Nevada video feeds
reported newly delivered frames, and Durango/Oso Blanca Live showed moving traffic,
vehicle overlays and advancing analysis timestamps. Closing that temporary Live
view restored Dashboard; explicit watch/block selections were preserved. A sustained
CPU/memory pilot is still open. The older CI SwiftUI type-check timeout was addressed
by splitting the feed browser into smaller view expressions; remote CI must confirm.
