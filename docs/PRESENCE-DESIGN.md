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
