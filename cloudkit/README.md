# CloudKit setup

The app talks to the public database of container
`iCloud.org.platewatch.platewatch`. The schema lives in
[`schema.ckdb`](schema.ckdb); the access model is explained in
`CloudKitBackend.swift` and [docs/BACKEND.md](../docs/BACKEND.md).

**Why two record families?** The public database has a single default zone and
everything readable is readable by *everyone*. So device uploads go to
`SightingSubmission` (creator-only), and only moderated records exist as
world-readable `Sighting` / `Vehicle` / `Agency`. A raw detection — and its plate
— is never publicly readable until a moderator publishes it.

## One-time setup (needs your Apple Developer account)

1. In the [CloudKit Dashboard](https://icloud.developer.apple.com/dashboard) make
   sure the container `iCloud.org.platewatch.platewatch` exists (Xcode creates it
   when you enable the iCloud/CloudKit capability with automatic signing).
2. Create a **CloudKit management token** (Dashboard → *Tokens & Keys* →
   *CloudKit Management Tokens*). Keep it out of the repo.
3. Save it and import the schema into **development**:

   ```bash
   xcrun cktool save-token --type management        # paste the token
   xcrun cktool validate-schema --team-id <TEAM> --container-id iCloud.org.platewatch.platewatch --environment development --file cloudkit/schema.ckdb
   xcrun cktool import-schema   --team-id <TEAM> --container-id iCloud.org.platewatch.platewatch --environment development --file cloudkit/schema.ckdb
   ```
4. Run a Debug build on a device signed into iCloud and record a sighting; check
   it appears under *Records → SightingSubmission* (development).
5. When happy: Dashboard → *Deploy Schema Changes…* (development → production).

## Publishing (moderation)

Accepted submissions are copied to `Sighting` by moderator tooling (dashboard
or a server-to-server key). `CloudKitBackend.publish(_:)` performs the guarded
privacy-safe save with the moderator-only CloudKit ACL and stable idempotency
record name. The operation is covered at the privacy boundary; a credentialed
production save and two-account isolation check remain deployment gates.
Until that worker is enabled, the public feed is empty on CloudKit builds; the
Vapor reference server's moderator console and exports are the working path
(see docs/BACKEND.md).

## Required indexes for the Hub's creator-owned history (2026-10-18)

`SightingSubmission` must declare `"___createdBy" REFERENCE QUERYABLE` (now in `schema.ckdb`). Without it, "Send CloudKit to Moderation"
and "Recover CloudKit history" fail with `Field 'createdBy' is not marked queryable`. Re-run `cktool validate-schema` / `import-schema`
against development, test the Hub handoff, then deploy to production. The owner runs this; no token belongs in the repo.


## PresenceLease (added 2026-10-19)
`schema.ckdb` now also declares `PresenceLease` (anonymous, 120-second live-presence leases; see `docs/PRESENCE-DESIGN.md`). Import it into
*development* with the same `cktool validate-schema` / `import-schema` commands, verify a Hub heartbeat, then deploy to production. Until it is
deployed the Hub shows "Offline · CloudKit schema not deployed" and nothing else is affected.
