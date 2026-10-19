# IDENTITY.md — turning what is painted on a vehicle into a cross-referenceable record

**Goal:** from one photo, automatically gather, recognise, identify and catalogue everything relevant
so it can be cross-referenced — and be honest about what was *read* versus *inferred* versus *unknown*.

> Example: a tailgate reading **WALTHAM** (charcoal on black), a plate header **Massachusetts** and a
> plate line **POLICE D756 OFFICIAL** ⇒ **Waltham Police Department, Massachusetts**, agency key
> `US-MA/waltham/police`, plate `D756` issued in MA (government/official design), vehicle Ford.

## The record (`PlateKit.VehicleIdentity`)
| Field | Meaning |
|---|---|
| `plate` | registration, issuing state (`MA`), design (`government-official`) — the registration is **redacted** unless the sighting may carry a plate |
| `agency` | display name, service, place, state, **`agencyKey`** (`US-MA/waltham/police`), centroid + GEOID, confidence, `isInferred`, `needsReview`, `alternatives`, `citation` |
| `unitNumbers`, `vehicle` | unit candidates (must contain a digit, never plate text) and make / model / traits from badges |
| `evidence[]` | every fact with its source (`doorText`, `plateText`, `plateHeader`, `classifier`, `gazetteer`, `inference`, `user`), the raw text it came from and a confidence |
| `consistency[]` | cross-checks ("plate state matches agency state", "out-of-state plate", "sighting is N km from the place") |

It is a **vehicle and agency** record. It never contains a person (LEGAL-ETHICS Rule 6).

## How the agency is inferred (`IdentityResolver`)
1. **Service** from door text (POLICE, SHERIFF, FIRE, EMS…, fuzzy for OCR errors) or, failing that, the official words printed on the plate.
2. **State** from the plate header (`Massachusetts` → `MA`), a reviewer's choice, or a state name in the door text.
3. **Place** — word n-grams from the OCR (including the slow dark-region pass) are matched against the
   **US Census Gazetteer** (59,670 places, towns, townships and counties; public domain, built by
   `scripts/build-gazetteer.py`) *within the plate's state*: exact, one-OCR-error, or fragment. A place
   supported by several fragments beats one supported by a single fragment.
4. **Ambiguity is reported, never guessed:** the same name in several states ⇒ place known, **state unknown**,
   candidates ranked by land area; different towns fitting a fragment ⇒ **place unclear**. A location hint
   (the sighting's ~1 km bucket) settles a tie only when the sighting is inside one candidate and the next is
   > 20 km and > 3× farther. A reviewer can settle it in the app ("Which one?").
5. **State-level agencies** (Highway Patrol, State Police) keep their verbatim name when read.
6. **Provenance:** every gazetteer-canonicalised name carries a `SourceCitation` (AGENTS.md guardrail 2).

## Low-contrast lettering
Dark-on-dark lettering is invisible to text recognition on raw pixels. For a vehicle that **already** has fleet
evidence and no resolved place, `VisionBaselineAnalyzer.nameFleetVehicles` re-reads dark regions with a levels
stretch at 2× scale (measured: gain 2–4 on a wide band recovers "WALTHAM"; contrast-only, inversion and tight
crops do not — see SPEC-REVIEW.md §1). The extra lines live in `VehicleObservation.enhancedText`, are used **only
to name the agency**, and are never read by the gate, so they cannot create or raise a fleet flag.

## LLM markings are grounded
Apple's on-device LLM can invent fields from garbled text — it returned the service "Hybridand" for badge text
"HYBRID AND…", which also fed the fleet gate. `SceneTextHeuristics.grounded` keeps an LLM field only when the OCR
text supports it (service must match the vocabulary, agency words and unit must appear in the text).

## Where it goes
Sighting DTO `identity` → server columns `agency_key`, `agency_name`, `agency_needs_review`, `plate_state` →
public feed / CSV / GeoJSON expose `agency_key`+`agency_name` **only when the identity was confident**.
CloudKit: the same fields on `SightingSubmission`, `agencyKey`/`agencyName` on the published `Sighting`
(`cloudkit/schema.ckdb`). The agency key is the join to fleet rosters (`FleetImporters`), FOIA targets and open data.

## Measured (hand-labelled agencies, 15 images; fleet metrics on all 62)
| | Mac | iPhone 16 Pro Max (device run) |
|---|---|---|
| Fleet recall / precision / civilian FP | 61 % / 100 % / 0 of 14 | **63 % / 100 % / 0 of 14** |
| Waltham photos (JPEG + original WebP) | Waltham Police Department, `US-MA/waltham/police` | same, both, not flagged for review |
| Agencies fully correct | 5 / 15 | 6 / 15 |
| Uncertain **and flagged**, right answer offered | 6 | — |
| Confidently wrong | 1 (a label mismatch: "State Patrol" vs "Highway Patrol") | 1 (same) |
| No vehicle found at all | 3 | 2 |

Most misses are the honest kind: an `Akron Fire Dept.` with no state anywhere on the vehicle is reported as
"place known, state unknown", not guessed.

## Known limits
- Place names are only as good as OCR; stylised lettering (e.g. the right-hand "POLICE" on the Waltham tailgate) is unreadable
  — the system then relies on the other evidence and says so.
- Land area is a crude prominence prior; population data would rank same-name places better.
- Unit numbers are weak evidence (bare-number lines).
- Agency names follow templates ("<Place> Police Department"); the true legal name can differ — the key, not the
  display name, is the join.
## Known gap: plate state from the plate design (found on the Minneapolis photo)
The Minnesota squad plate reads only "POLICE"; its state banner ("Minnesota", cursive, blue on pale
blue, ~12 px tall) and "10,000 lakes" are **not readable by Apple Vision** under any scale/contrast
treatment tried (3–8× scale, levels stretch gain 2–4, banner and strip crops). So the state stays
unresolved ("Minneapolis, state unknown — which one?"; MN is offered first). The fix is the
plate-design classifier (MODEL-TRAINING §4c, Create ML Image Classification on plate crops, one
class per state) — not more OCR. Case is eval id 902 (`eval/user/`, gitignored).

## Where the location hint comes from (it is a property of the frame's *source*)
The identity resolver uses a coarse location only to settle ambiguous place names ("Minneapolis" is in MN, NC and KS).
It must come from where the **frame** was captured, never from the device that happens to be running the analysis:

| Source | Location hint |
|---|---|
| Live capture (iPhone) | the phone's current ~1 km bucket |
| Imported photo | the photo's own EXIF GPS (`PlateKit.ImageLocation`); **none** if the photo has no GPS |
| Public camera feed (511/DOT, transit, port cams) | the camera's catalogued fixed position — `PublicFeedSource.geohash6` is mandatory |
| Hub (IP cameras, folder drops) | the operator-set `homeGeohash6` for that camera |

Wired in the Hub (verified 2026-10-18): every ingest path — folder drops, the local HTTP endpoint, public camera feeds and
selected Live frames — records fleet hits through `HubController.recordFleetHits`, which calls `FeedIdentity.resolve`
(`apps/macos-hub/Sources/FeedIdentity.swift`) and puts the result in the submission's `identity`. The location hint is the
frame source's geohash centre (a feed's catalogued position or the operator-set home bucket for Hub cameras), never this Mac's;
frames below full resolution are flagged for review and carry no registration; the smallest frames assert no identity. Pinned by
`FeedIdentityTests` (camera position settles Minneapolis MN vs elsewhere, tier rules, identity survives the wire encoding) on top of
the PlateKit resolver tests. Feed frames have **no phone GPS and no EXIF** — fixed-camera metadata is the only reliable location
there. A source with no known location falls back to "state unknown — which one?" (and, later, to plate-state evidence).
Live check 2026-10-18 (installed signed Hub, Waltham eval photo POSTed to the Hub's local `/snapshot` endpoint, which shares
`recordFleetHits` with feeds): the Review pane showed the agency from the resolver (`US-MA/unknown/police`, tier full, 70 %). The place
"Waltham" was **not** resolved in the Hub path although the eval harness resolves it for the same photo — open, not yet traced
(first suspects: the thorough dark-region naming pass not running with the Hub's analysis context, or the OCR text differing).
The Moderation pane could not show an agency at that point because the moderator queue API and the CloudKit→moderation handoff
carried none; both now do (agency key/name only, withheld while flagged for review), covered by server and PlateSync tests. The live
hand-off was blocked by a CloudKit schema gap (`createdBy` not queryable on `SightingSubmission`); `cloudkit/schema.ckdb` now
declares it, but the owner must import and deploy the schema before the handoff works. Still open: the place-name gap above and the
plate-design classifier for plate state (see "Known gap").
