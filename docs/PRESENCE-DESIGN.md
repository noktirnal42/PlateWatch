# Live operator presence and feed demand

PlateWatch can show aggregate operational demand without exposing an operator
identity or retaining an activity history. A client that is actively processing
a feed would hold a random, install-local session identifier and send a short
lease heartbeat. The server would keep only leases that have not expired (for
example, 90 seconds) and return aggregate counts:

- connected processing consoles across Hub, iOS, and watch companion clients;
- active processors by feed ID; and
- whether a feed is selected for processing by at least one console.

The dashboard would label these as **live estimates** and show the last refresh
time. A stopped client naturally disappears after the lease expires. No user
names, IP addresses, plate values, frame data, or historical session records
are required. A client may disable presence publication in Settings; the local
feed continues to work when presence is disabled or the server is unavailable.

Implementation boundary:

1. Add an ephemeral presence service to the reference server with heartbeat,
   release, and aggregate-read routes. Keep leases in memory or a bounded TTL
   store; never include them in public sightings or CloudKit records.
2. Add a small `PlateSync` presence client with a 30–60 second heartbeat,
   cancellation on pane/feed stop, and exponential backoff.
3. Have Hub, iOS, and watch publish only while an operator has explicitly
   selected active processing. Do not count passive catalogue browsing.
4. Add dashboard and feed-row badges with accessible labels and stale-state
   treatment. Tests must cover expiry, duplicate heartbeats, release, and
   server outage fallback.

This is feasible with the current REST boundary. CloudKit remains the
submission/sighting sync channel; it is not used as a presence database.

## Diagnosis and fixes — 2026-10-19 ("sessions and live processors don't work on any platform")
Three independent causes, found by running the Hub against a freshly built server:
1. **Heartbeat rejected with HTTP 413.** The Hub sent every watched feed ID (1,295 → ~50 KB); the server keeps ≤ 100 and Vapor's default body limit is 16 KB. Every heartbeat failed, so the dashboard showed "—". Fixed in `PresenceHeartbeat` (IDs capped at 100, deterministic order, unit-tested to stay under 16 KB) — applies to Hub, iOS and watch.
2. **The installed local reference server predates presence.** `~/Library/Application Support/PlateWatchServer/bin/App` (built 2026-10-15) answers 404 for `/v1/presence`; presence landed 2026-10-16. A current build (`swift build --package-path server`) serves heartbeat/aggregate/release correctly; with it the Hub reported 1 session, 1 processor and its stats. **Done 2026-10-19 with the owner's approval:** the old binary and `Public/` were backed up to `…/PlateWatchServer/backup-20261019-144453/`, the current debug build was swapped in and the launchd job restarted; the live Hub then reported 1 session, 1 processor and its frame stats from `127.0.0.1:8083`.
3. **Phones and watches cannot reach `127.0.0.1` on the Mac.** Presence resolves its server through `SyncBackends.mirrorURL()`, whose default is localhost:8083, so counts only ever worked Mac-to-Mac. `mirrorURL()` now honours the saved server address (iOS About → Backend, Hub Settings → "Presence server"), but a shared, reachable server (HTTPS) is still required for cross-device counts. The watch keeps its own defaults domain and has no setting yet. Presence is in-memory on that server and is deliberately not available on CloudKit-only deployments.
Verified: PlateSync unit test; Hub ↔ temporary server end-to-end (1 session). Not verified: iOS/watch against a shared server.

## Decision 2026-10-19 — presence moves to CloudKit (owner-approved)
**Why:** the REST presence server listens on one Mac's localhost, so a phone or watch could never reach it; cross-device counts need
infrastructure every platform already has. CloudKit is that infrastructure (signed Hub and iPhone), so the earlier line "CloudKit is
not used as a presence database" is **superseded for presence only** — it is still not used for anything else live, and presence
records never mix with sighting records.
**Design (supersedes steps 1–2 of "Implementation boundary" above for signed builds):**
- Record type `PresenceLease` in the *public* database (`cloudkit/schema.ckdb`): `expiresAt`, `platform`, `activeProcessing`, `feedIDs`
  (≤ 100) and, for the Hub only, five dashboard counters. World-readable, writable only by the creating iCloud user. No names, plates,
  frames, locations or history are stored.
- One record per install: `recordName = "lease-" + hash(random install-local session id)`. The raw id is never published and an install
  overwrites its own record, so the table stays bounded by installs. A lease expires after **120 s** (heartbeats every 45 s); a crashed or
  killed client vanishes without cleanup. A clean stop deletes the record.
- Aggregation is client-side (`PresenceAggregator`): unexpired leases → active sessions, processors (`activeProcessing`), per-feed counts,
  and Hub-only totals. These are **live estimates**: a public database cannot stop a forged lease, so no figure is audited.
- **Hub** and **iPhone** publish and read through `PresenceServices.makeDefault()` (CloudKit when entitled, the REST server for unsigned
  development builds). The iPhone publishes only while the opt-in toggle is on and the app is active; it counts as a *processor* only while
  the camera is scanning. The **watch** publishes nothing: it shows the aggregate the phone reads and relays over WatchConnectivity
  (`presenceAggregate`, counts only) and shows "—" when that is missing or older than 10 minutes.
- Clear errors: schema missing → "Offline · CloudKit schema not deployed"; no iCloud → "Offline · iCloud sign-in needed".
**Owner steps before it works (nothing was deployed by the agent):** import `cloudkit/schema.ckdb` into *development*
(`xcrun cktool validate-schema` / `import-schema`, see `cloudkit/README.md`), test, then *Deploy Schema Changes…* to production.
**Known limits:** the public database exposes each record's opaque creator id to readers (the same property the sighting records have), so a
lease is *linkable per iCloud account* though it names no one; rotating the install session id does not change that. Expired leases from
installs that never return stay in the table until a moderator purges them (a purge command is not built). Verified: unit tests for record
naming, mapping, expiry and aggregation. **Not verified:** any live CloudKit read/write, the iPhone and watch builds on devices.

### Development schema status — 2026-10-19
The CloudKit Console (container `iCloud.org.platewatch.platewatch`, **Development**) already had `PresenceLease` with all eleven fields (queryable/sortable indexes on each), and the security roles matched `schema.ckdb` (`_world` read only; `_icloud` and `_creator` listed). Metadata indexes (`recordName`, `createdTimestamp`) show "None" and were left unchanged because queries use `expiresAt`. **Verified live in Development:** the installed Hub (signed, CloudKit-entitled) published a lease and its dashboard showed "Live demand 1 sessions · 1 processors". **Not done:** deploying the schema to Production (owner step), and the iPhone/watch builds have not been run on devices, so the phone-to-Hub count and the watch relay are still unverified.

### Cross-device check — 2026-10-19 17:05
With the Release iPhone build installed and presence switched on, the Hub dashboard showed **2 sessions · 1 processor** (Hub + iPhone; the phone was not scanning). The watch relay and Production (the schema was only in Development) are still unverified.
