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
2. **The installed local reference server predates presence.** `~/Library/Application Support/PlateWatchServer/bin/App` (built 2026-10-15) answers 404 for `/v1/presence`; presence landed 2026-10-16. A current build (`swift build --package-path server`) serves heartbeat/aggregate/release correctly; with it the Hub reported 1 session, 1 processor and its stats. **Replacing the installed binary is an owner decision and has not been done.**
3. **Phones and watches cannot reach `127.0.0.1` on the Mac.** Presence resolves its server through `SyncBackends.mirrorURL()`, whose default is localhost:8083, so counts only ever worked Mac-to-Mac. `mirrorURL()` now honours the saved server address (iOS About → Backend, Hub Settings → "Presence server"), but a shared, reachable server (HTTPS) is still required for cross-device counts. The watch keeps its own defaults domain and has no setting yet. Presence is in-memory on that server and is deliberately not available on CloudKit-only deployments.
Verified: PlateSync unit test; Hub ↔ temporary server end-to-end (1 session). Not verified: iOS/watch against a shared server.
