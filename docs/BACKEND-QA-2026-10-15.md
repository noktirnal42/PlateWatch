# Hub backend connection QA — 2026-10-15

## Verified cause and repair

The installed Hub had no iCloud container entitlement. Its enrolled moderation URL was
correct (`http://127.0.0.1:8083`), but no server was listening. PlateSync's unsigned-build
fallback incorrectly used 8080. HubApp also constructed an unused backend without running
any outbox delivery, so a local Review item was never proof of server delivery.

- Added Hub CloudKit capability for the existing container. Automatic provisioning produced
  a signed build with the container and CloudKit service entitlements.
- Explicitly set both SwiftData review-store configurations to `cloudKitDatabase: .none`.
  Adding the entitlement initially exposed SwiftData's automatic CloudKit selection and
  caused a startup failure; the local-only store repair was built and relaunched successfully.
  Existing local Review count remains two. No store reset or queue submission was performed.
- Corrected REST fallback to 8083 and reject malformed/credential-bearing or remote HTTP
  overrides. Two new backend-selection tests pass; all 15 PlateSync tests and 36 Hub tests pass (four opt-in skips).
- Settings now has read-only connection checks. The signed running Hub reports an available
  iCloud account and a successful REST health check. Account status does not assert record
  access, submission, sync completion, or production client environment.
- Moderation identifies the REST endpoint and distinguishes unavailable, empty and last-loaded
  queue states. Native navigation and authenticated loads succeeded: zero queue rows,
  zero takedowns, two existing audit rows. No moderation decisions were made.
- A fresh `cktool export-schema` from production succeeded. Agency, Sighting,
  SightingSubmission and Vehicle exist; submissions grant creator read/write and iCloud create.
  Two-account isolation and moderator publication are still unverified/unimplemented.

## Final boundary and recovery checks

REST now strips `cropJPEGBase64` from outgoing requests regardless of fleet confidence.
Unconfirmed submissions also strip plate, identity registration and exact coordinates before
encoding. Local evidence is unchanged. An intercepted actual REST request fails the test if
any forbidden field arrives. All 18 PlateSync tests and 53 reference-server tests pass.
The build/run verifier now requires the process to survive five seconds rather than claiming
success from an instant PID check.

Native stop/reconnect QA: stopping the local service and clicking Refresh produced
“Queue unavailable” with the server-unavailable explanation. Restarting the service and
clicking Refresh restored the authenticated empty queue without restarting the app.
The installed app is signed and its local Review queue remains two items; no items were sent.

## Local reference service

Built `server/` from the repair checkout. PostgreSQL 17 was already running and its existing
PlateWatch database is used. A per-user `org.platewatch.reference-server` LaunchAgent now runs
an installed copy of that server under Application Support, restarts on failure and starts
at login. It binds loopback 8083. Its runner reads the existing owner-only moderator token
file; no token is embedded in service arguments, plist, source or diagnostic output.

The repository entrypoint is `python3 script/run_local_server.py` after
`swift build --package-path server`. It accepts `--binary` and `--token-file` locations.
The service's executable, runner and logs are under the user's Application Support
`PlateWatchServer` directory; its plist is under the user's Library/LaunchAgents directory.
Use `launchctl bootout gui/$(id -u)/org.platewatch.reference-server` to stop it, or
`launchctl kickstart -k gui/$(id -u)/org.platewatch.reference-server` to restart it.
The server's existing retention and nightly export policies apply; no synthetic sightings
were inserted. Database counts before connection QA: zero sightings, two audit entries.

## Remaining delivery milestones

1. The Hub Review pane now exposes operator-triggered **Confirm selected** and
   **Sync pending** actions. Confirmation is encoded in `userConfirmed`; explicit
   unconfirmed rows remain pending at the reference server and never carry a plate
   into CloudKit. Sync preserves retry state and reports delivery. This is delivery
   only; moderator publication remains separate.
   The signed macOS Hub is CloudKit-entitled, so a successful sync goes to the
   private CloudKit `SightingSubmission` store rather than the loopback REST
   moderation queue. The Hub retains a bounded `ReceivedSubmissionReceipt` and
   now reports the destination plus accepted/rejected counts, so a zero-row REST
   queue does not by itself indicate that a CloudKit submission was lost.
   Settings now offers an explicit delivery destination: Automatic, CloudKit,
   or the local reference server when the operator needs the REST moderation
   queue immediately.
2. CloudKit read/write proof using approved test records, plus two-account creator isolation.
3. CloudKit moderator publication tool with audit/provenance and withdrawal behavior.
4. Optional REST/CloudKit mirroring, hosted service and device-to-device proof.

## Cross-launch identity correction — 2026-10-16

CloudKit record names that are not UUIDs now map to IDs using SHA-256 rather than
Swift's process-randomized `Hasher`. The previous mapping could change a public
agency, vehicle or sighting ID after every app relaunch, which made delta and
receipt reconciliation unreliable even when the CloudKit record itself was
unchanged. A PlateSync regression test covers repeat calls and distinct names.

The local REST moderation queue and CloudKit are separate stores. A healthy server or an
available iCloud account must never be labeled a completed end-to-end publication pipeline.

## Recovery after an older Hub sync — 2026-10-16

An older signed Hub removed a local `PendingSubmission` after CloudKit accepted it
without retaining a local receipt. Those records are creator-readable
`SightingSubmission` rows in the same iCloud account; they do not appear in the
loopback REST Moderation queue until a moderator publishes them. The repaired Hub
adds **Review → Recover CloudKit history**, which queries only the current user's
creator-readable submission metadata and rebuilds bounded local receipt rows. It
does not restore plate text, raw frames, exact coordinates, or submission payloads.
Use it after installing an entitled build while signed into the same iCloud account.

The same Review pane also offers **Send CloudKit to Moderation**. This is an
explicit, operator-triggered handoff for the local reference server: it reads
creator-owned submission fields, reconstructs the moderation DTO without crops or
exact coordinates, and sends each row through `RESTBackend` so its privacy gate
and idempotency rules run again. It does not delete or mutate CloudKit records and
is not automatic two-way mirroring.

## REST mirror packaging verification — 2026-10-16

The multi-stage `server/Dockerfile` was built with Colima for `linux/arm64` and
tagged `platewatch-server:qa` (image digest `sha256:e7d7d838bb8c42d4695809d819bfc582f687cb5b36dbb01faaa70bf728fd605e`).
The Linux build includes the server test target and uses `swift-crypto` when
CryptoKit is unavailable. `swift test --package-path server --disable-sandbox`
passed 56 tests with zero failures. This verifies packaging only; it does not
prove a production database, CloudKit publication, or two-account isolation.
