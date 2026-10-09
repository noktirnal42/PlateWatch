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
| id, vehicleID?, plateText? | — | vehicle link may be null pre-verification |
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
