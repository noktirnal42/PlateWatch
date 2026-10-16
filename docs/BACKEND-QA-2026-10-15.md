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
2. CloudKit read/write proof using approved test records, plus two-account creator isolation.
3. CloudKit moderator publication tool with audit/provenance and withdrawal behavior.
4. Optional REST/CloudKit mirroring, hosted service and device-to-device proof.

The local REST moderation queue and CloudKit are separate stores. A healthy server or an
available iCloud account must never be labeled a completed end-to-end publication pipeline.
