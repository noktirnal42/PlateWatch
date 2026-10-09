# BACKEND.md — CloudKit-first, free-forever hosting strategy

## Decision: CloudKit public database is the primary backend

The user's requirement: free Apple technology now, free option later for
other platforms. CloudKit satisfies both:

| Requirement | How it's met |
|---|---|
| Free for developers | CloudKit development environment is free; production quotas (asset/DB/transfer) scale with users and comfortably fit a structured civic records database. Media is stored as small crops + hashes, not raw video, staying far under quota. |
| "Server" without ops | No VM, no billing account, no uptime duty. Apple runs it. |
| All Apple platforms | Native `CloudKit` framework on iOS/macOS/watchOS. |
| Community shared DB | **Public database** in one container: every user reads/writes the same civic dataset. Roles moderate. |
| Push alerts | `CKQuerySubscription` delivers watchlist hits as silent pushes — free APNs, no server code. This powers the watchOS alert feature. |
| Offline-first mobile capture | `PlateSync` outbox + CloudKit retry semantics. |

Container: `iCloud.org.platewatch` (register under the project's
Apple Developer account). Record types mirror `docs/DATA-MODEL.md`.

### What CloudKit deliberately does not do here

- No per-user private data (we don't use the private DB).
- No heavy media (raw frames/plate photos as full-res CKAssets are capped;
  we store 512px plate crops + SHA-256 of originals kept by the uploader).
- Compute/importers run as **client-side jobs or GitHub Actions cron**,
  writing to a moderation zone — not as server code.

## Cross-platform expansion (non-Apple clients)

CloudKit's Swift frameworks don't exist elsewhere, so cross-platform clients
use the **reference REST protocol**. Two free ways to serve it:

### Option A — Self-hosted mirror (default reference impl in `server/`)
- Vapor + Postgres, AGPL, `docker compose up`.
- Free-forever hosts that fit it:
  - **Oracle Cloud Always Free** (4 ARM cores / 24 GB RAM is genuinely free
    forever — the best free VM on the market, plenty for this workload).
  - **Render / Fly.io free tiers** (suspect long-term; oracle preferred).
  - A volunteer's Mac mini in a closet — literally fine at our scale.
- The mirror **two-way syncs with CloudKit** via CloudKit Web Services
  (server-to-server token) so Apple users and everyone else share one truth.
  Sync service is a small Swift job in `server/` (`CloudKitMirrorService`).

### Option B — Cloudflare free tier (documented alternative)
Workers + D1 (SQLite) free tier can serve the read API + nightly exports for
essentially unlimited read traffic. A community TypeScript port of
`server/Sources/App/DTO` is the only work item; write path stays on CloudKit.

### Nightly public exports
Regardless of hosting: a scheduled job publishes the full public dataset as
CSV/GeoJSON (plus `.torrent`/IPFS pins later) — the dataset must outlive any
single host. "Librarians, not gatekeepers."

## Identity & moderation without accounts on our own server

- CloudKit identity = opaque `userRecordID`; `Device` records carry an
  ed25519 key generated on-device (`CryptoKit`) used to sign submissions.
- Roles (reader/contributor/moderator) live on a `Membership` record in the
  public DB; bootstrap moderators are provisioned by the project owner.
- The REST mirror authenticates by the same ed25519 signature scheme, so a
  device identity works on both backends.

## Cost ceiling targets (keep us free)

| Resource | Budget rule |
|---|---|
| CKAsset storage | ≤ 40 KB plate crop per sighting (thumbnails), no raw video |
| CloudKit transfer | Exponential backoff + delta pulls; watchlists are query subscriptions, not polling |
| Mirror VM | Fits Oracle Always Free ARM shape; Postgres ≤ 20 GB |
