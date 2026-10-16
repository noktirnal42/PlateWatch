# BACKEND.md — CloudKit-first, free-forever hosting strategy

> **Status (2026-10-15): Production CloudKit schema verified by a read-only management export.**
> `Agency`, `Sighting`, `SightingSubmission`, and `Vehicle` exist; submission permissions
> grant creator read/write and iCloud create. This is schema evidence, not a two-account
> isolation test or proof of a client submission. The Hub previously shipped without its
> CloudKit capability, and its local moderation server was stopped. Connection diagnostics
> now distinguish CloudKit account availability from the reference server's health.
> The Hub review queue remains local; automatic delivery and CloudKit moderator publication
> are not enabled. See [connection QA](BACKEND-QA-2026-10-15.md).

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

Container: `iCloud.org.platewatch.platewatch` (register under the project's
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
- Two-way CloudKit mirroring is planned, not implemented. The REST database and
  CloudKit remain separate stores until a reviewed server-to-server sync service exists.

### REST delta-sync protocol (stable contract for non-Apple clients)

- `POST /v1/sightings` with an `Idempotency-Key` header. The key is the
  client's content-addressed digest (SHA-256 prefix, see
  `OutboxDrainer.idempotencyKey`) — the same detection resubmitted after a
  restart or retry must produce the same key, or the server stores it twice.
- `GET /v1/sightings?cursor=…&limit=…` pages newest-first, ordered by
  `(capturedAt DESC, id DESC)`. The response's `nextCursor` is
  `"<ISO-8601-with-fractional-seconds>|<last-row-UUID>"` — echo it back
  verbatim to resume strictly after the boundary row. Second-precision
  timestamps collide constantly, so the ID tiebreaker is load-bearing: a
  bare-timestamp filter would skip or loop rows at the page boundary.
  A cursor that is only a date (legacy `since` style) is still accepted
  and treated as "rows newer than this instant".

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

### Reference server operations (`server/`)

| Setting | Default | Purpose |
|---|---|---|
| `PORT` | `8083` | HTTP port (8080 is often taken by a local Apache) |
| `HOST` | `127.0.0.1` | Bind address; set `0.0.0.0` only behind a TLS proxy |
| `DATABASE_URL` | local docker-compose Postgres | Use `sslmode=require` in production |
| `MODERATOR_TOKEN` | unset (console disabled) | Password for the moderator console; ≥ 24 characters |

**Public feed rule.** `GET /v1/sightings` and the exports return only
`fleetConfirmed` rows. `pending` and `redacted` rows never leave the server.
Plate text is persisted only for `fleetConfirmed` rows (LEGAL-ETHICS Rule 1).

**Moderator console.** `GET /moderator` lists `pending` sightings (unit
number, ~1 km area, fleet confidence, ID; never a plate). Each decision is a
`POST` that must carry an HMAC form token derived from `MODERATOR_TOKEN`, so
a cross-site form cannot act on a sighting. Responses are `no-store`, use a
strict CSP, and contain no third-party assets. Authentication is HTTP Basic
(any username, password = `MODERATOR_TOKEN`); unset or short tokens return 404.
Every decision is logged by sighting ID only.

**Publication guardrails** (`PublicationPolicy`). Every public surface (feed, exports, aggregates, agency report) starts from
`Sighting.publicQuery`: fleet-confirmed, not taken down, and captured at least `PUBLISH_DELAY_HOURS` ago (default 24, max 720), so
the feed cannot track a vehicle in near-real time. Rows older than `RETENTION_DAYS` (default 21, 1–365) are deleted by a daily
job, plate text included. `POST /v1/takedowns` (`sightingID?`, `reason`, `contact?`) lets anyone ask for a sighting to be removed;
moderators list open requests and resolve them (`hide` = never published again, `dismiss`) through `/moderator/api/takedowns`.
Moderator decisions, takedown requests/resolutions and retention purges are written to an append-only `audit_log`
(action + target ID, never content).

**Public aggregates.** `GET /v1/aggregates/heatmap?since=&until=&agencyID=`
returns counts per geohash-6 cell and per UTC day for fleet-confirmed sightings.
Any bucket with fewer than 5 sightings is withheld, and only the number of
withheld buckets is reported. The window defaults to 30 days and is capped at
366. No per-sighting data is returned.

**Nightly export.** `NightlyExportJob` writes the public dataset at 03:00 UTC.
It is not scheduled under `swift test`.

## Cost ceiling targets (keep us free)

| Resource | Budget rule |
|---|---|
| CKAsset storage | ≤ 40 KB plate crop per sighting (thumbnails), no raw video |
| CloudKit transfer | Exponential backoff + delta pulls; watchlists are query subscriptions, not polling |
| Mirror VM | Fits Oracle Always Free ARM shape; Postgres ≤ 20 GB |
