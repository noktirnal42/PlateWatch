# DATA-MODEL.md

Single logical schema, three physical forms:
`PlateKit` Swift types (canonical) → CloudKit record types → SQL tables
(reference server + nightly exports). The DTOs are the protocol.

## Core entities

### Vehicle
Canonical taxpayer-funded asset.
| Field | Type | Notes |
|---|---|---|
| id | UUID | |
| primaryPlate | `Plate` (embedded) | nullable if identified by unit only |
| unitNumber | String? | as marked on vehicle |
| agencyID | UUID (→ Agency) | |
| kind | VehicleClass | patrol, fireEngine, ambulance, publicWorks, transit, schoolBus, federal, military, otherFleet |
| make / model / yearRange / colors | String / String / ClosedRange<Int>? / [String] | classifier output + human edits |
| featurePrintHash | String? | locality-sensitive re-ID anchor |
| status | active / decommissioned / auctioned | from fleet/auction records |
| provenance | [SourceCitation] | required for every non-user-visible field |

### Plate
| Field | Type |
|---|---|
| text | normalized uppercase, no spaces |
| issuingRegion | String (ISO 3166-2 where applicable) |
| country | String (ISO 3166-1) |
| plateDesign | String? (e.g. "CA-exempt", "US-GOV") — from design classifier |
| confidence | 0…1 |
| lastSeen | Date |

### Agency
| Field | Type |
|---|---|
| id / name / shortName | UUID / String / String |
| level | municipal / county / state / federal / tribal / specialDistrict |
| jurisdictionGeo | GeoJSON string (coarse) |
| parentAgencyID | UUID? |
| publicContact | URL? |

### UnitAssignment (unit number ↔ vehicle ↔ officer/agency-member)
| Field | Type | Notes |
|---|---|---|
| agencyID, unitNumber, vehicleID, subjectName? | — | subjectName **only** from cited public rosters |
| role | patrol / k9 / supervisor / command / support | |
| effectiveFrom / To | Date? | |
| provenance | [SourceCitation] | **required, no exceptions** |
| confidence | inferred / singleSource / officialRoster | |

### Sighting
| Field | Type | Notes |
|---|---|---|
| id, vehicleID?, plateText? | — | vehicle link may be null pre-verification; `plateText` is stored only when `moderationState = fleetConfirmed` (server-enforced) |
| capturedAt | Date (UTC) | device clock + server receipt delta stored |
| geo | lat/lon | exact only when fleet-confirmed; else ~1 km bucket |
| heading, roadClass | Float?, String? | |
| cropHashSHA256 | String | integrity anchor for the stored plate crop |
| cropAssetRef | CKAsset ref / object key | ≤ 40 KB thumbnail |
| deviceIDHash | String | ed25519 pubkey hash; not identity-bearing |
| moderationState | pending / fleetConfirmed / redacted / rejected | default pending |
| fleetConfidence | 0…1 | from on-device gate |

### SourceCitation
`sourceType` ∈ { agencyRoster, fleetRegistry, foiaRelease, auctionListing,
officialPost, openDataPortal, nhtsaVpic, communityVerified } · `url` ·
`retrievedAt` · `excerptHashSHA256` · `submittedByDeviceHash`.

### Watchlist — user-scoped (never published)
`vehicleID | plateText | featurePrintAnchor` + `notifyViaCKSubscription: Bool`.

### SafetyHold
Moderator-only list (entityRef, reason, resolution) enforcing
LEGAL-ETHICS Rule 4. Cascades: blocks watchlist alerts and public exports.

## Confidence model

| Tier | Meaning | Publishable |
|---|---|---|
| inferred | ML-only, unverified | internal only |
| singleSource | one public citation | yes, labeled |
| officialRoster | agency-published source | yes |
| communityVerified | 2+ independent contributors + moderator | yes |

## CloudKit mapping

One record type per entity (`CD_Vehicle`, `CD_Sighting`, …), public DB,
custom zone `fleet-main` for entities, `moderation` zone for holds/reports.
`CKReference` for parent links (delete action: none — we never cascade-delete
the public record; we tombstone with moderationState).

## Indexing expectations (server mirror)

- `Sighting(plateText, capturedAt)` composite; `Sighting` geohash-6 column
  for ~1 km buckets; `Vehicle(primaryPlateText)` unique-ish (collisions
  allowed across regions); full-text on `Agency.name`.

## Planned entities (M6/M7 — designed, not implemented)

These land with `AccountabilityKit`/`FeedIngest` (see
[CAMERA-SOURCES.md](CAMERA-SOURCES.md),
[ACCOUNTABILITY-DATA.md](ACCOUNTABILITY-DATA.md)). Listed here so schemas,
DTOs and the server mirror are designed against one model — none of these
exist in code yet.

### PublicFeedSource (M6)
A published public camera feed (traffic cam, port/transit cam). Fields: name,
URL, kind (`snapshotJPEG | hls | rtsp`), `refreshInterval`, static
`geohash6` (the camera's own location — fixed installations), and one required
`SourceCitation` for the feed listing. Frames from a feed go through the same
`RedactionGate` as handheld captures; the feed citation rides on every
derived record.

### OfficialProfile (M7)
A public official/employee **in their public capacity**. Fields: name, role,
agency (reference), public photo URL + retrieval date, `SourceCitation`s
(≥ 1 mandatory). No home address, no personal contact data. Reference photos
are cited public images; face embeddings computed from them stay on-device
and are never persisted or synced (LEGAL-ETHICS Rule 6 conditions). A match
is stored only as a labeled, confirmed person link — never as biometric data.

### IncidentRecord (M7)
A cited public record about an official or agency: kind
(`brady | decertification | lawsuit | news | report`), verbatim reference
(docket/report identifier), status, publisher, citations. Allegation ≠ fact:
content is stored as released, never summarized beyond the filing.

### Person linking (M7)
`UnitAssignment` (existing) gains the person reference + an `inference`
confidence. Auto-inferred links never auto-publish; publication requires a
moderator confirmation that itself carries a citation.

## Network crop boundary (2026-10-15)

`SightingSubmissionDTO.cropJPEGBase64` is an intact local Review crop. It is not blacked out or
omitted because of neighboring vehicles/text (LEGAL-ETHICS Rule 1, local Review exception). REST submission explicitly
omits it; CloudKit maps no image field. Only the crop hash crosses that boundary. REST also
reapplies plate/identity-registration and exact-coordinate redaction for unconfirmed fleet
submissions, including older queued payloads. DTO wire field compatibility is unchanged.

## Local hash-addressed evidence recovery (2026-10-15)

After a Hub queue record saves, its intact JPEG is also stored locally at
`Application Support/PlateWatchHub/Evidence/<sha256>.jpg`. The original inline DTO
copy remains. Opening Review backfills valid existing images into this archive.
Review and the local agent evidence command fall back to the archive when inline bytes
are absent, damaged or fail their recorded hash. Every archived read verifies the SHA-256,
bounded JPEG and file type. Archive directories/files are owner-only (0700/0600).

A hash identifies bytes; it cannot reconstruct an image when no copy survives. This
second copy protects against loss/corruption of one queue payload, not disk loss.
Intentional rejection deletes the archive copy after the final queued reference to the
same hash is removed. No raw frames or image bytes are uploaded by this feature.
