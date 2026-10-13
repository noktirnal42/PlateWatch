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

Accepted submissions are copied to `Sighting` by the moderator tool (dashboard
or a server-to-server key). That tool is **not built yet** — until it exists the
public feed is empty on CloudKit builds; the Vapor reference server's moderator
console and exports are the working path (see docs/BACKEND.md).
