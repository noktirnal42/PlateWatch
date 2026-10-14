# Where plate reading is on, and where it is off

**Not legal advice.** This is how the software behaves today and why, based on `docs/research/FEED-LEGAL-RESEARCH.md`
(statute text read where marked VERIFIED, secondary sources otherwise). The statutes change; counsel should confirm
before anyone relies on this list. Owner position (2026-10-14): PlateWatch is not an ALPR in the usual sense, so it is not
"ALPR use". That position is recorded here, but it is **not yet confirmed by counsel**, so the software keeps the gate below.

## What "plate reading off" means

Only plate **text recognition** is switched off. Everything else still runs: vehicle detection, fleet lettering and unit
numbers read from doors, agency identification, and sightings. Off means the recognizer is not run at all (not merely
hidden), so nothing is read and nothing can be stored.

## How the Hub decides (`PlateKit.JurisdictionPolicy`)

1. A camera or home location is mapped to the states that have a catalogued place within **30 km** of it.
2. If **any** of those states is in the "off" lists below, plate reading is **off** for that source (this is why a camera
   just across a state line from Maine or New Hampshire is also off).
3. If the location is **unknown**, or no US place is catalogued within 30 km (including anywhere outside the US), plate
   reading is **off** — the gate fails closed.
4. Otherwise plate reading is **on**, and the redaction gate still applies: plates are persisted only for
   fleet-confirmed vehicles (`docs/LEGAL-ETHICS.md`).

Set the Hub's home location in **Settings → Home location** (Use my location, latitude/longitude, or a Plus Code).
Public feeds use each camera's own catalogued position, not the home location.

## Off by default

| State | Why | Status |
|---|---|---|
| Maine | 29-A MRSA §2117-A: a person may not use an automated licence plate recognition system except listed public uses | Statute text read (VERIFIED) |
| New Hampshire | RSA 261:75-b: ALPR only by law enforcement for listed purposes | Statute text read (VERIFIED) |
| Arkansas | Ark. Code 12-12-1801 to -1808: ALPR operation unlawful except listed uses; 2025 amendments reportedly extend it | Pending counsel (secondary source) |
| Idaho | Non-law-enforcement use prohibited (per NCSL) | Pending counsel (secondary source) |
| Kentucky | Use unlawful except listed purposes (per NCSL) | Pending counsel (secondary source) |
| Connecticut | Retention limits and restrictions on private vendors (per NCSL) | Pending counsel (secondary source) |

Plus the **30 km border margin** around each of these.

## On by default, with notes (reviewed)

| State | Note |
|---|---|
| California | Civ. Code 1798.90.5–.55: "operators" and "end-users" need security safeguards and a public usage and privacy policy. Publish one (research item 20). Open question whether the project is an operator. |
| Minnesota | Minn. Stat. 13.824 is aimed at law-enforcement data, but its definition can reach privately owned readers whose data are shared with law enforcement. |
| Virginia | Va. Code 2.2-5517 regulates agencies and their vendors; not a general private ban. |
| Colorado | Retention rules for government custodians. |
| Utah, Vermont, Oregon, Illinois, Iowa, North Carolina, Tennessee, Georgia, Montana, Nebraska, New Mexico, Alabama, Kansas, Maryland, New Jersey | Government-focused retention and use rules; no general private-use ban found. Iowa DOT's site terms separately limit automated request rates. |
| Florida | Only a transportation-department permit action for law-enforcement readers on state rights-of-way; no general ban. |
| Texas | A state directive on permits for law-enforcement readers; no private-use statute found. |

## On by default, not yet researched

Alaska, Arizona, Delaware, District of Columbia, Hawaii, Indiana, Louisiana, Massachusetts, Michigan, Mississippi, Missouri,
Nevada, New York, North Dakota, Ohio, Oklahoma, Pennsylvania, Rhode Island, South Carolina, South Dakota, Washington,
West Virginia, Wisconsin, Wyoming.

"On" here means only that nothing in the research found a general ban; **these were not researched**. Treat them as unknown
until counsel reviews them.

## Outside the United States

Off everywhere (no US place within 30 km). Canadian, Finnish, Singaporean and other feeds can still be used for vehicle
and fleet detection, but not plate reading.

## Gaps to close

- The handheld iPhone/Watch apps do **not** apply this gate yet (it is wired into the Hub and feed ingest).
- Counsel questions: does reading plates on a third-party feed count as ALPR "use"? Does an on-device, discard-immediately
  design change the answer? Do the four "pending counsel" states really apply? (`docs/research/FEED-LEGAL-RESEARCH.md`.)
- The state lists live in `packages/PlateKit/Sources/PlateKit/Identity/JurisdictionPolicy.swift`
  (`platesRestricted`, `platesPendingCounsel`). Change them there, update this page, and run the PlateKit tests.
